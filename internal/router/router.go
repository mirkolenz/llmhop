// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers.
package router

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/mirkolenz/llmhop/internal/authz"
	"github.com/mirkolenz/llmhop/internal/config"
)

// New returns an http.Handler that serves the OpenAI models API from the
// configured models and proxies every other request to the backend matching
// its JSON "model" field, all guarded by the configured auth tokens. Only
// GET /health is served unauthenticated.
func New(cfg *config.Config) (http.Handler, error) {
	proxies := make(map[string]*httputil.ReverseProxy, len(cfg.Models))
	for name, m := range cfg.Models {
		u, err := url.Parse(m.URL)
		if err != nil {
			return nil, fmt.Errorf("model %q: invalid url %q: %w", name, m.URL, err)
		}
		proxy := httputil.NewSingleHostReverseProxy(u)
		if len(m.Headers) > 0 {
			orig := proxy.Director
			proxy.Director = func(r *http.Request) {
				orig(r)
				for k, v := range m.Headers {
					r.Header.Set(k, v)
				}
			}
		}
		proxies[name] = proxy
	}

	tokens := make([][]byte, len(cfg.AuthTokens))
	for i, t := range cfg.AuthTokens {
		tokens[i] = []byte(t)
	}

	mux := http.NewServeMux()
	registerModels(mux, cfg)
	mux.HandleFunc("/", proxyHandler(proxies, cfg.MaxBodyBytes))

	// Health sits outside the auth middleware: liveness probes and downstream
	// load balancers must be able to check the proxy without a token.
	root := http.NewServeMux()
	registerHealth(root, cfg)
	root.Handle("/", authMiddleware(tokens, mux))

	return root, nil
}

// proxyHandler buffers each request body so it can peek at the JSON "model"
// field, then forwards the request verbatim to the matching backend.
//
// The body is fully buffered. A streaming json.Decoder that stops at the
// "model" field would let us forward very large bodies (e.g. base64 images)
// without copying them into memory first; see the roadmap in README.md.
func proxyHandler(proxies map[string]*httputil.ReverseProxy, maxBytes int64) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
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

		var probe struct {
			Model string `json:"model"`
		}
		_ = json.Unmarshal(body, &probe)
		proxy, ok := proxies[probe.Model]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", probe.Model), http.StatusNotFound)
			return
		}

		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
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
