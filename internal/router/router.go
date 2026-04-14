// Package router builds the HTTP handler that authenticates incoming
// requests, picks a backend based on the JSON "model" field and forwards
// the request through a per-model reverse proxy with injected headers.
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

// New returns an http.Handler that proxies each request to the backend
// matching its JSON "model" field, guarded by the configured auth tokens.
func New(cfg *config.Config) (http.Handler, error) {
	proxies := make(map[string]*httputil.ReverseProxy, len(cfg.Models))
	for name, model := range cfg.Models {
		u, err := url.Parse(model.URL)
		if err != nil {
			return nil, fmt.Errorf("model %q: invalid url %q: %w", name, model.URL, err)
		}
		proxy := httputil.NewSingleHostReverseProxy(u)
		if len(model.Headers) > 0 {
			orig := proxy.Director
			proxy.Director = func(r *http.Request) {
				orig(r)
				for k, v := range model.Headers {
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

	maxBytes := cfg.MaxBodyBytes

	// The request body is fully buffered so we can peek at the "model"
	// field. A streaming json.Decoder that stops at that field would let
	// us forward very large bodies (e.g. base64 images) without copying
	// them into memory first; see the roadmap in README.md.
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if len(tokens) > 0 {
			if !authz.CheckBearer(req.Header.Get("Authorization"), tokens) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			req.Header.Del("Authorization")
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
	}), nil
}
