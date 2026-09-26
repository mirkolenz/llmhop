// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers.
package router

import (
	"bytes"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"

	"github.com/mirkolenz/llmhop/internal/authz"
	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// New returns an http.Handler that serves the OpenAI models API from the
// configured models and proxies every other request to the backend matching
// its JSON "model" field, all guarded by the configured auth tokens. Only
// GET /health is served unauthenticated.
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
			Transport: up.Transport,
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
	mux.HandleFunc("/", proxyHandler(proxies, cfg.MaxBodyBytes, cfg.MaxConcurrentRequests))

	// Health sits outside the auth middleware: liveness probes and downstream
	// load balancers must be able to check the proxy without a token.
	root := http.NewServeMux()
	registerHealth(root, len(listed))
	root.Handle("/", authMiddleware(tokens, mux))

	return root, nil
}

// proxyHandler buffers each request body so it can peek at the JSON "model"
// field, then forwards the request verbatim to the matching backend.
//
// Full buffering validates the entire JSON body before forwarding.
func proxyHandler(proxies map[string]*httputil.ReverseProxy, maxBytes int64, maxConcurrent int) http.HandlerFunc {
	var slots chan struct{}

	if maxConcurrent > 0 {
		slots = make(chan struct{}, maxConcurrent)
	}

	return func(w http.ResponseWriter, req *http.Request) {
		if maxBytes > 0 && req.ContentLength > maxBytes {
			http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
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
		body, err := io.ReadAll(req.Body)
		if err != nil {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
				return
			}
			http.Error(w, "failed to read request body", http.StatusBadRequest)
			return
		}

		var request struct {
			Model *string `json:"model"`
		}
		if err := json.Unmarshal(body, &request); err != nil {
			http.Error(w, "invalid JSON request body", http.StatusBadRequest)
			return
		}

		if request.Model == nil {
			http.Error(w, "missing model", http.StatusBadRequest)
			return
		}

		proxy, ok := proxies[*request.Model]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", *request.Model), http.StatusNotFound)
			return
		}

		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		if len(req.Trailer) > 0 {
			req.ContentLength = -1
		}

		proxy.ServeHTTP(w, req)
	}
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
