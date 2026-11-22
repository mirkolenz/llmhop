// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers, selected by the /llmhop/proxy/{model}/ path
// prefix or the "model" field of a JSON or multipart body, and balanced over
// the servers of the model.
package router

import (
	"bytes"
	"cmp"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
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
	// load balancers and Prometheus must be able to check the proxy without
	// a token.
	logged := logRequests(api, &limits.metrics)
	root := http.NewServeMux()
	registerHealth(root, len(objects))
	probes := newProber(models)
	registerReadiness(root, probes)
	root.Handle("GET "+reservedPrefix+"metrics", metricsOnly(cfg.Listen, &exporter{limits: limits, models: models, prober: probes}))
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

// bufferedBody is a request body read in full, charged to the budget of
// buffered bytes until released.
type bufferedBody struct {
	data    []byte
	release func()
}

// buffer reads the body of req within the budget of buffered bytes, or
// writes an error response and returns nil.
func buffer(w http.ResponseWriter, req *http.Request, budget *semaphore.Weighted) *bufferedBody {
	charged := &chargedReader{r: req.Body, budget: budget}

	data, err := readBody(w, charged)
	if err != nil {
		charged.release()

		switch _, tooLarge := errors.AsType[*http.MaxBytesError](err); {
		case tooLarge:
			bodyTooLarge(w)
		case errors.Is(err, errBudgetExceeded):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusServiceUnavailable, "buffer_budget_exceeded", "request body buffer budget exhausted, retry later")
		case errors.Is(err, os.ErrDeadlineExceeded):
			writeError(w, http.StatusRequestTimeout, "request_body_timeout", "request body timeout")
		default:
			writeError(w, http.StatusBadRequest, "invalid_request_body", "failed to read request body")
		}

		return nil
	}

	return &bufferedBody{data: data, release: sync.OnceFunc(charged.release)}
}

// forward returns req carrying body as a replayBody, and the function that
// lets go of it and the budget once a response is accepted.
func (b *bufferedBody) forward(req *http.Request, body []byte) (*http.Request, func()) {
	rb := newReplayBody(body, b.release)
	req.Body, _ = rb.open()
	req.GetBody = rb.open
	req.ContentLength = int64(len(body))

	// Only a chunked body carries the trailers, read along with the body.
	if len(req.Trailer) > 0 {
		req.ContentLength = -1
	}

	return req, rb.drop
}

// maxModelField bounds the "model" field of a multipart body.
const maxModelField = 4 << 10

// modelField reads the "model" field of a JSON object body, returned with
// its members, or of a multipart one as uploads such as
// /v1/audio/transcriptions send, or describes why a body lacks one.
//
// Full buffering validates the entire JSON body before forwarding, which
// also rejects a duplicate "model" that a backend might resolve differently.
func modelField(contentType string, body []byte) (string, *object, *apiErrorBody) {
	if mediaType, params, err := mime.ParseMediaType(contentType); err == nil && mediaType == "multipart/form-data" {
		name, invalid := multipartModel(multipart.NewReader(bytes.NewReader(body), params["boundary"]))

		return name, nil, invalid
	}

	obj, err := parseObject(body)
	if err != nil {
		return "", nil, errInvalidJSON
	}

	var name *string
	if value, ok := obj.member("model"); ok && json.Unmarshal(value, &name) != nil {
		return "", nil, errInvalidJSON
	}

	if name == nil {
		return "", nil, errMissingModel
	}

	return *name, obj, nil
}

// object is a JSON object with the spans of its member values.
type object struct {
	data    []byte
	members map[string][2]int
	// end is the offset of its closing brace.
	end int
}

// parseObject reads the members of a JSON object in one pass, which also
// validates it whole and rejects duplicate members. The decoder parses the
// buffer in place.
func parseObject(data []byte) (*object, error) {
	dec := jsontext.NewDecoder(bytes.NewBuffer(data))
	if token, err := dec.ReadToken(); err != nil || token.Kind() != '{' {
		return nil, errNoObject
	}

	o := &object{data: data, members: make(map[string][2]int)}

	for dec.PeekKind() == '"' {
		token, err := dec.ReadToken()
		if err != nil {
			return nil, err
		}

		// Read before the value voids the token.
		name := token.String()

		value, err := dec.ReadValue()
		if err != nil {
			return nil, err
		}

		end := int(dec.InputOffset())
		o.members[name] = [2]int{end - len(value), end}
	}

	if _, err := dec.ReadToken(); err != nil {
		return nil, err
	}

	o.end = int(dec.InputOffset()) - 1

	if _, err := dec.ReadToken(); !errors.Is(err, io.EOF) {
		return nil, errNoObject
	}

	return o, nil
}

var errNoObject = errors.New("not a single JSON object")

// member returns the value of a member, of which a nil object has none.
func (o *object) member(name string) (jsontext.Value, bool) {
	if o == nil {
		return nil, false
	}

	span, ok := o.members[name]

	return o.data[span[0]:span[1]], ok
}

// lookup returns the value at a path of members through nested objects.
func (o *object) lookup(path []string) (jsontext.Value, bool) {
	value, ok := o.member(path[0])

	for _, name := range path[1:] {
		inner, err := parseObject(value)
		if !ok || err != nil {
			return nil, false
		}

		value, ok = inner.member(name)
	}

	return value, ok
}

// text returns the string at a path of members, empty for any other value.
func (o *object) text(path ...string) string {
	var s string
	value, _ := o.lookup(path)
	_ = json.Unmarshal(value, &s)

	return s
}

// patch returns the object with the values of set, replacing those of its
// members and appending the others, in one pass that keeps everything else.
func (o *object) patch(set map[string]jsontext.Value) []byte {
	type splice struct {
		start, end int
		value      []byte
	}

	splices := make([]splice, 0, len(set)+1)
	var added []byte
	size := len(o.data)

	for _, name := range slices.Sorted(maps.Keys(set)) {
		if span, ok := o.members[name]; ok {
			splices = append(splices, splice{span[0], span[1], set[name]})
			size += len(set[name]) - (span[1] - span[0])

			continue
		}

		if len(o.members) > 0 || len(added) > 0 {
			added = append(added, ',')
		}

		added, _ = jsontext.AppendQuote(added, name)
		added = append(append(added, ':'), set[name]...)
	}

	splices = append(splices, splice{o.end, o.end, added})
	slices.SortFunc(splices, func(a, b splice) int { return cmp.Compare(a.start, b.start) })

	out := make([]byte, 0, size+len(added))
	at := 0

	for _, s := range splices {
		out = append(append(out, o.data[at:s.start]...), s.value...)
		at = s.end
	}

	return append(out, o.data[at:]...)
}

// multipartModel reads the only "model" field of a form, which the whole
// form must hold exactly once and in full, since the backend reads the
// form itself and must not see another model than the one routed by.
func multipartModel(r *multipart.Reader) (string, *apiErrorBody) {
	var model *string

	for {
		part, err := r.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}

		if err != nil {
			return "", errInvalidMultipart
		}

		if part.FormName() != "model" {
			continue
		}

		value, err := io.ReadAll(io.LimitReader(part, maxModelField+1))
		if err != nil || model != nil || len(value) > maxModelField {
			return "", errInvalidMultipart
		}

		model = new(string(value))
	}

	if model == nil {
		return "", errMissingModel
	}

	return *model, nil
}

var (
	errInvalidJSON      = &apiErrorBody{Code: "invalid_json", Message: "invalid JSON request body"}
	errMissingModel     = &apiErrorBody{Code: "missing_model", Message: "missing model"}
	errInvalidMultipart = &apiErrorBody{Code: "invalid_multipart", Message: "invalid multipart request body or model field"}
	errAliasRewrite     = &apiErrorBody{Code: "unsupported_alias_body", Message: "this alias rewrites the model of JSON bodies only"}
)

// readBody reads the whole body within bodyTimeout, growing the buffer as
// data arrives rather than by the declared length, so a stalled client holds
// neither a budget nor memory it never sends.
func readBody(w http.ResponseWriter, body io.Reader) ([]byte, error) {
	rc := http.NewResponseController(w)
	// Fails only for writers without deadlines, such as test recorders.
	_ = rc.SetReadDeadline(time.Now().Add(bodyTimeout))
	data, err := io.ReadAll(body)
	// Cleared, since expiring once the body was read would cancel the request.
	_ = rc.SetReadDeadline(time.Time{})

	return data, err
}

var errBudgetExceeded = errors.New("buffered request bodies exceed their budget")

// chargedReader takes every byte it reads from the budget of buffered bytes,
// which bounds the bodies held at once, so a body is charged only for the
// data that has arrived.
type chargedReader struct {
	r      io.Reader
	budget *semaphore.Weighted
	// n counts the bytes charged so far.
	n int64
}

// release returns the bytes charged so far to the budget.
func (c *chargedReader) release() {
	c.budget.Release(c.n)
}

func (c *chargedReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if !c.budget.TryAcquire(int64(n)) {
		return 0, errBudgetExceeded
	}

	c.n += int64(n)

	return n, err
}

// replayBody hands a buffered body to the transport, which resends it to
// the same or another server until a response is accepted. Then drop lets go
// of the buffer and releases its budget, so a response streamed for long
// holds neither.
type replayBody struct {
	buf  atomic.Pointer[[]byte]
	drop func()
}

func newReplayBody(body []byte, release func()) *replayBody {
	rb := &replayBody{}
	rb.buf.Store(&body)
	rb.drop = sync.OnceFunc(func() {
		rb.buf.Store(nil)
		release()
	})

	return rb
}

var errBodySent = errors.New("buffered request body already sent")

func (rb *replayBody) open() (io.ReadCloser, error) {
	buf := rb.buf.Load()
	if buf == nil {
		return nil, errBodySent
	}

	return &dropReader{buf: *buf}, nil
}

// dropReader reads a buffer and lets go of it at EOF, so the request, which
// lives as long as its response, does not keep the buffer alive.
type dropReader struct {
	buf []byte
}

func (r *dropReader) Read(p []byte) (int, error) {
	if len(r.buf) == 0 {
		r.buf = nil

		return 0, io.EOF
	}

	n := copy(p, r.buf)
	r.buf = r.buf[n:]

	return n, nil
}

func (*dropReader) Close() error { return nil }

// bodyTooLarge reports a request body exceeding the size limit.
func bodyTooLarge(w http.ResponseWriter) {
	writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body too large")
}

// statusClientClosed is nginx's status of a request its client abandoned,
// which only the log and the metrics see.
const statusClientClosed = 499

// proxyError maps a streamed body exceeding the size limit to 413, a client
// gone before the response to 499, a backend exceeding its response timeout
// to 504, and every other upstream failure to 502 like the default
// ReverseProxy handler.
func proxyError(w http.ResponseWriter, req *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)

		return
	}

	if req.Context().Err() != nil {
		w.WriteHeader(statusClientClosed)

		return
	}

	slog.Error("proxy", "id", req.Header.Get(requestIDHeader), "err", err)

	if netErr, ok := errors.AsType[net.Error](err); ok && netErr.Timeout() {
		writeError(w, http.StatusGatewayTimeout, "backend_timeout", "backend response timeout")

		return
	}

	writeError(w, http.StatusBadGateway, "bad_gateway", "backend unreachable")
}
