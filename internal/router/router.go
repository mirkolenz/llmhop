// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers, selected by the /llmhop/proxy/{model}/ path
// prefix or the "model" field of a JSON or multipart body, and balanced over
// the servers of the model.
package router

import (
	"encoding/json/jsontext"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"golang.org/x/sync/semaphore"

	"github.com/mirkolenz/llmhop/internal/config"
)

// New returns the handler of cfg, which serves the OpenAI models API from
// the configured models and proxies every request below
// /llmhop/proxy/{model}/ to the model of its path, and every other
// one outside /llmhop/ to the model named by its body, each within the
// policy of its client. Health, readiness and, on the listeners with
// metrics, the metrics of llmhop are served unauthenticated and unlogged.
// It is immutable, so a reload replaces it, sharing the limits and metrics
// with the router it replaces, which drop the models and clients it lacks.
// Its probes run from Start until it is closed, so that only serving
// reaches the backends.
func New(cfg *config.Config, limits *Limits) (*Router, error) {
	rt := &routes{
		rewrites:     make(map[string]jsontext.Value),
		affinity:     cfg.Affinity,
		bodyAffinity: slices.ContainsFunc(cfg.Affinity, func(s config.AffinitySource) bool { return len(s.Body) > 0 }),
		limits:       limits,
	}
	var models []*model

	for name, m := range cfg.Models {
		md, err := newModel(name, m, limits.queue(name, m.MaxConcurrentRequests), limits.pool(name, m), cfg.RequiresAuth())
		if err != nil {
			return nil, fmt.Errorf("models.%s: %w", name, err)
		}

		rt.models.add(name, md)

		for alias, a := range m.Aliases {
			rt.models.add(alias, md)

			if a.Model != "" {
				// Quoting a string from valid JSON cannot fail.
				rt.rewrites[alias], _ = jsontext.AppendQuote(nil, a.Model)
			}
		}

		models = append(models, md)
	}

	for name := range rt.models.exact {
		rt.segments = max(rt.segments, strings.Count(name, "/")+1)
	}

	objects := catalog(cfg.Models)
	buffered := limits.bufferBudget(cfg.MaxBufferedBytes)
	mux := http.NewServeMux()
	registerModels(mux, objects)
	mux.Handle("/", rt.proxyHandler(cfg.MaxBodyBytes, buffered, false))
	mux.Handle(proxyPrefix, rt.proxyHandler(cfg.MaxBodyBytes, buffered, true))

	auth := newAuthenticator(cfg, limits)
	api := auth.wrap(mux)

	if len(cfg.CORSOrigins) > 0 {
		api = auth.cors(cfg.CORSOrigins, api)
	}

	// Health, readiness and metrics sit outside the auth middleware: probes,
	// load balancers and monitoring must be able to check the proxy without
	// a token.
	logged := logRequests(api, &limits.metrics)
	root := http.NewServeMux()
	registerHealth(root, len(objects))
	probes := newProber(models)
	registerReadiness(root, probes)
	root.Handle("GET "+reservedPrefix+"metrics", metricsOnly(cfg.Listen, &metricsHandler{limits: limits, models: models, prober: probes}))
	root.Handle(proxyPrefix, logged)
	root.HandleFunc(reservedPrefix, notFound)
	root.Handle("/", logged)

	limits.retain(cfg)

	return &Router{root, probes}, nil
}

// Router is the handler of one config.
type Router struct {
	http.Handler
	probes *prober
}

// Start probes the servers of r in the background, before it serves.
func (r *Router) Start() {
	r.probes.start()
}

// Close stops the probes of r, while its requests in flight finish.
func (r *Router) Close() {
	r.probes.stop()
}

// reservedPrefix starts the paths of llmhop's own API, which no backend
// receives as they are.
const reservedPrefix = "/llmhop/"

// proxyPrefix starts the paths of the proxy to any path of a model.
const proxyPrefix = reservedPrefix + "proxy/"

// routes resolves a model name to its model.
type routes struct {
	// models holds every model name, alias and wildcard.
	models matcher[*model]
	// rewrites holds the encoded model name each rewriting alias forwards.
	rewrites map[string]jsontext.Value
	// segments is the most path segments of an exact name, which bounds
	// the prefixes of a path that may name a model.
	segments int
	affinity []config.AffinitySource
	// bodyAffinity is whether a source of affinity reads the body.
	bodyAffinity bool
	limits       *Limits
}

// bodyTimeout bounds reading a body buffered for its "model" field,
// so a slow client cannot hold buffered bytes for long.
const bodyTimeout = time.Minute

// proxyHandler forwards each request to the model named by the "model"
// field of its body, which is buffered within the `buffered` budget until
// the backend starts its response and edited for a rewriting alias,
// or if routed by its path, which is stripped up to its proxy segment,
// and the body forwarded verbatim, buffered only if JSON that may carry an
// affinity key, such as the session of a native SGLang request.
// The limits apply only once the model is resolved,
// so a saturated model never blocks requests to another.
func (rt *routes) proxyHandler(maxBytes int64, buffered *semaphore.Weighted, routed bool) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if maxBytes > 0 {
			if req.ContentLength > maxBytes {
				bodyTooLarge(w)

				return
			}

			req.Body = http.MaxBytesReader(w, req.Body, maxBytes)
		}

		var name string
		var m *model
		var b *bufferedBody
		var obj *object

		if routed {
			name, m = rt.routeModel(req.URL)

			if m != nil && rt.keyedBody(m, req.Header) {
				if b = buffer(w, req, buffered); b == nil {
					return
				}

				defer b.release()

				// A body other than an object carries no key, yet passes.
				obj, _ = parseObject(b.data)
			}
		} else {
			if b = buffer(w, req, buffered); b == nil {
				return
			}

			defer b.release()

			var invalid *apiErrorBody
			if name, obj, invalid = modelField(req.Header.Get("Content-Type"), b.data); invalid != nil {
				writeError(w, http.StatusBadRequest, invalid.Code, invalid.Message)

				return
			}

			m, _ = rt.models.lookup(name)
		}

		e := entryOf(req)
		e.model = clip(name)

		if m == nil {
			unknownModel(w, name)

			return
		}

		e.served = m.name
		c := e.client

		if !c.allows(name) {
			modelNotAllowed(w, name)

			return
		}

		if !take(w, c.limiters) {
			return
		}

		a := &attempt{}

		if b != nil {
			body := b.data

			if upstream, ok := rt.rewrites[name]; ok && !routed {
				// A form would have to be rebuilt.
				if obj == nil {
					writeError(w, http.StatusBadRequest, errAliasRewrite.Code, errAliasRewrite.Message)

					return
				}

				body = obj.patch(map[string]jsontext.Value{"model": upstream})
			}

			req, a.accept = b.forward(req, body)
		} else if req.Body != nil && req.Body != http.NoBody {
			a.upload = &upload{ReadCloser: req.Body}
			req.Body = a.upload
		}

		// Computed before queueing, so a large body holds no slot meanwhile.
		if len(m.targets) > 1 {
			a.affinity = affinityOf(req, rt.affinity, obj)
		}

		m.serve(w, req, a, &ticket{client: c})
	}
}

// keyedBody reports whether a body routed to m by its path may carry its
// affinity key, which only JSON does, sent as such or without a media type.
func (rt *routes) keyedBody(m *model, h http.Header) bool {
	if !rt.bodyAffinity || len(m.targets) < 2 {
		return false
	}

	media := mediaType(h)

	return media == "" || media == "application/json"
}

// routeModel resolves the model of a /llmhop/proxy/{model}/{path} URL and
// strips all but the path from it, keeping its escapes. The model is the
// longest name starting the escaped path, where a name with `/` may be
// written raw or with `%2F`, and an unknown model is reported as the first
// segment. Wildcards do not apply, since they leave the end of the name open.
func (rt *routes) routeModel(u *url.URL) (string, *model) {
	segments := strings.Split(strings.TrimPrefix(u.EscapedPath(), proxyPrefix), "/")

	for n := min(len(segments), rt.segments); n > 0; n-- {
		name, err := url.PathUnescape(strings.Join(segments[:n], "/"))
		if m, ok := rt.models.exact[name]; ok && err == nil {
			u.RawPath = "/" + strings.Join(segments[n:], "/")
			u.Path, _ = url.PathUnescape(u.RawPath)

			return name, m
		}
	}

	name, _ := url.PathUnescape(segments[0])

	return name, nil
}
