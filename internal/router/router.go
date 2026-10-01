// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers, selected by the /route/{model} path prefix or the JSON
// "model" field.
package router

import (
	"bytes"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"strings"

	"github.com/mirkolenz/llmhop/internal/authz"
	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// New returns an http.Handler that serves the OpenAI models API from the
// configured models and proxies every other request to the backend named by
// its /route/{model} path prefix or else its JSON "model" field, all guarded
// by the configured auth tokens. Only GET /health is served unauthenticated.
func New(cfg *config.Config) (http.Handler, error) {
	proxies := make(map[string]*httputil.ReverseProxy, len(cfg.Models))
	for name, m := range cfg.Models {
		up, err := upstream.Parse(m.URL)
		if err != nil {
			return nil, fmt.Errorf("model %q: %w", name, err)
		}

		// Go carries Host outside the header map, so a configured one overrides r.Out.Host.
		headers := make(http.Header, len(m.Headers))
		for k, v := range m.Headers {
			headers.Set(k, v)
		}

		host := headers.Get("Host")
		headers.Del("Host")

		proxies[name] = &httputil.ReverseProxy{
			Rewrite: func(r *httputil.ProxyRequest) {
				// ReverseProxy drops unparsable queries, forward them verbatim instead.
				r.Out.URL.RawQuery = r.In.URL.RawQuery
				r.SetURL(up.URL)
				r.Out.Host = cmp.Or(host, r.In.Host)
				r.SetXForwarded()

				for k, v := range headers {
					r.Out.Header[k] = v
				}
			},
			Transport:    up.Transport,
			ErrorHandler: proxyError,
		}
	}

	tokens := make([][]byte, len(cfg.AuthTokens))
	for i, t := range cfg.AuthTokens {
		tokens[i] = []byte(t)
	}

	// Shared, so both endpoints reporting the catalog agree on it.
	listed := cfg.Listed()

	mux := http.NewServeMux()
	registerModels(mux, listed)
	proxy := proxyHandler(proxies, cfg.MaxBodyBytes, cfg.MaxConcurrentRequests)
	mux.Handle(routePrefix+"{model}/{path...}", proxy)
	mux.Handle("/", proxy)

	// Health sits outside the auth middleware: liveness probes and downstream
	// load balancers must be able to check the proxy without a token.
	root := http.NewServeMux()
	registerHealth(root, len(listed))
	root.Handle("/", authMiddleware(tokens, mux))

	return root, nil
}

// routePrefix starts path-routed requests, chosen so it cannot collide with
// OpenAI paths such as GET /v1/models/{model}.
const routePrefix = "/route/"

// proxyHandler forwards each request to the backend named by its
// /route/{model} path prefix, which is stripped and the body streamed,
// or else by its JSON "model" field, for which the body is buffered.
func proxyHandler(proxies map[string]*httputil.ReverseProxy, maxBytes int64, maxConcurrent int) http.HandlerFunc {
	var slots chan struct{}

	if maxConcurrent > 0 {
		slots = make(chan struct{}, maxConcurrent)
	}

	return func(w http.ResponseWriter, req *http.Request) {
		if maxBytes > 0 && req.ContentLength > maxBytes {
			bodyTooLarge(w)
			return
		}

		if slots != nil {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			default:
				http.Error(w, "too many concurrent requests", http.StatusServiceUnavailable)
				return
			}
		}

		if maxBytes > 0 {
			req.Body = http.MaxBytesReader(w, req.Body, maxBytes)
		}

		name := req.PathValue("model")
		if name == "" {
			var ok bool
			if name, ok = bodyModel(w, req); !ok {
				return
			}
		} else {
			// Cut the escaped path, so escapes such as %2F in the remainder survive.
			_, rest, _ := strings.Cut(strings.TrimPrefix(req.URL.EscapedPath(), routePrefix), "/")
			req.URL.RawPath = "/" + rest
			req.URL.Path = "/" + req.PathValue("path")
		}

		proxy, ok := proxies[name]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", name), http.StatusNotFound)
			return
		}

		proxy.ServeHTTP(w, req)
	}
}

// bodyModel buffers the body to read its JSON "model" field and restores it
// for forwarding, or writes an error response and reports false.
//
// Full buffering validates the entire JSON body before forwarding.
func bodyModel(w http.ResponseWriter, req *http.Request) (string, bool) {
	body, err := io.ReadAll(req.Body)
	if err != nil {
		if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
			bodyTooLarge(w)
			return "", false
		}
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return "", false
	}

	var request struct {
		Model *string `json:"model"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		http.Error(w, "invalid JSON request body", http.StatusBadRequest)
		return "", false
	}

	if request.Model == nil {
		http.Error(w, "missing model", http.StatusBadRequest)
		return "", false
	}

	req.Body = io.NopCloser(bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	if len(req.Trailer) > 0 {
		req.ContentLength = -1
	}

	return *request.Model, true
}

// bodyTooLarge reports a request body exceeding the size limit.
func bodyTooLarge(w http.ResponseWriter) {
	http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
}

// proxyError maps a streamed body exceeding the size limit to 413, and every
// other upstream failure to 502 like the default ReverseProxy handler.
func proxyError(w http.ResponseWriter, _ *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)
		return
	}

	log.Printf("http: proxy error: %v", err)
	w.WriteHeader(http.StatusBadGateway)
}

// authMiddleware gates next with the configured bearer tokens and strips the
// client Authorization header before it reaches any backend. With no tokens
// configured it is a no-op and the header is forwarded verbatim.
func authMiddleware(tokens [][]byte, next http.Handler) http.Handler {
	if len(tokens) == 0 {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !authz.CheckBearer(req.Header.Get("Authorization"), tokens) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		req.Header.Del("Authorization")
		next.ServeHTTP(w, req)
	})
}
