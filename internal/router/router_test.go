package router

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/iotest"

	"github.com/mirkolenz/llmhop/internal/config"
)

type capturedRequest struct {
	method string
	body   string
	header http.Header
	host   string
	path   string
	query  string
}

func newBackend(t *testing.T) (*httptest.Server, *capturedRequest) {
	t.Helper()
	captured := &capturedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		captured.method = r.Method
		captured.body = string(body)
		captured.header = r.Header.Clone()
		captured.host = r.Host
		captured.path = r.URL.Path
		captured.query = r.URL.RawQuery
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("backend ok"))
	}))
	t.Cleanup(srv.Close)
	return srv, captured
}

func post(t *testing.T, handler http.Handler, body, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func get(t *testing.T, handler http.Handler, path, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

func newHandler(t *testing.T, auth []string, models ...string) http.Handler {
	t.Helper()
	backend, _ := newBackend(t)
	m := make(map[string]config.Model, len(models))
	for _, name := range models {
		m[name] = config.Model{URL: backend.URL}
	}
	h, err := New(&config.Config{AuthTokens: auth, Models: m})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestInvalidModelURL(t *testing.T) {
	cfg := &config.Config{Models: map[string]config.Model{
		"bad": {URL: "://not a url"},
	}}
	if _, err := New(cfg); err == nil {
		t.Fatal("expected error for malformed URL")
	}
}

func TestModelsAPI(t *testing.T) {
	h := newHandler(t, nil, "b", "a")

	t.Run("list returns sorted models", func(t *testing.T) {
		rec := get(t, h, "/v1/models", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("got status %d", rec.Code)
		}
		var got modelList
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if got.Object != "list" {
			t.Fatalf("got object %q", got.Object)
		}
		if len(got.Data) != 2 || got.Data[0].ID != "a" || got.Data[1].ID != "b" {
			t.Fatalf("got models %+v", got.Data)
		}
		if got.Data[0].Object != "model" || got.Data[0].OwnedBy != "llmhop" {
			t.Fatalf("got model %+v", got.Data[0])
		}
	})

	t.Run("individual model", func(t *testing.T) {
		rec := get(t, h, "/v1/models/a", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("got status %d", rec.Code)
		}
		var m model
		if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		if m.ID != "a" || m.Object != "model" {
			t.Fatalf("got model %+v", m)
		}
	})

	t.Run("unknown model returns 404", func(t *testing.T) {
		if rec := get(t, h, "/v1/models/nope", ""); rec.Code != http.StatusNotFound {
			t.Fatalf("got status %d", rec.Code)
		}
	})
}

func TestHealth(t *testing.T) {
	h := newHandler(t, []string{"secret"}, "a", "b")

	rec := get(t, h, "/health", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d, want 200 without a token", rec.Code)
	}

	var got health
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}

	if got.Status != "ok" || got.Models != 2 {
		t.Fatalf("got %+v", got)
	}
}

func TestModelsAPIAuth(t *testing.T) {
	h := newHandler(t, []string{"secret"}, "m")
	if rec := get(t, h, "/v1/models", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("missing token: got status %d", rec.Code)
	}
	if rec := get(t, h, "/v1/models", "Bearer secret"); rec.Code != http.StatusOK {
		t.Fatalf("valid token: got status %d", rec.Code)
	}
}

func TestRouterRequests(t *testing.T) {
	cases := []struct {
		name       string
		auth       []string
		headers    map[string]string
		body       string
		authHeader string
		maxBody    int64
		wantCode   int
		wantBody   string
		checkFwd   func(t *testing.T, req *capturedRequest)
	}{
		{
			name:     "invalid JSON returns 400",
			body:     `{"model":`,
			wantCode: http.StatusBadRequest,
		},
		{
			name:     "unknown model returns 404",
			body:     `{"model": "nope"}`,
			wantCode: http.StatusNotFound,
		},
		{
			name:     "known model is proxied",
			body:     `{"model": "m", "prompt": "hi"}`,
			wantCode: http.StatusOK,
			wantBody: "backend ok",
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if r.body != `{"model": "m", "prompt": "hi"}` {
					t.Fatalf("backend saw body %q", r.body)
				}
			},
		},
		{
			name:       "auth disabled passes Authorization through",
			body:       `{"model": "m"}`,
			authHeader: "Bearer client-token",
			wantCode:   http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if got := r.header.Get("Authorization"); got != "Bearer client-token" {
					t.Fatalf("backend saw Authorization %q", got)
				}
			},
		},
		{
			name:     "auth enabled rejects missing header",
			auth:     []string{"secret"},
			body:     `{"model": "m"}`,
			wantCode: http.StatusUnauthorized,
		},
		{
			name:       "auth enabled rejects wrong token",
			auth:       []string{"secret"},
			body:       `{"model": "m"}`,
			authHeader: "Bearer nope",
			wantCode:   http.StatusUnauthorized,
		},
		{
			name:     "auth runs before model lookup",
			auth:     []string{"secret"},
			body:     `{"model": "unknown"}`,
			wantCode: http.StatusUnauthorized,
		},
		{
			name:       "auth strips client Authorization before forwarding",
			auth:       []string{"secret"},
			body:       `{"model": "m"}`,
			authHeader: "Bearer secret",
			wantCode:   http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if got := r.header.Get("Authorization"); got != "" {
					t.Fatalf("backend saw Authorization %q, want stripped", got)
				}
			},
		},
		{
			name:    "model headers are injected",
			headers: map[string]string{"Authorization": "Bearer upstream", "Host": "backend.example", "X-Injected": "yes"},
			body:    `{"model": "m"}`,
			// client Authorization should be overridden by injected value.
			authHeader: "Bearer client-token",
			wantCode:   http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if got := r.header.Get("Authorization"); got != "Bearer upstream" {
					t.Fatalf("got Authorization %q", got)
				}
				if got := r.header.Get("X-Injected"); got != "yes" {
					t.Fatalf("got X-Injected %q", got)
				}

				if r.host != "backend.example" {
					t.Fatalf("backend saw host %q", r.host)
				}
			},
		},
		{
			name:     "oversized body returns 413",
			maxBody:  16,
			body:     `{"model": "m", "prompt": "` + strings.Repeat("x", 100) + `"}`,
			wantCode: http.StatusRequestEntityTooLarge,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			backend, captured := newBackend(t)
			cfg := &config.Config{
				AuthTokens:   c.auth,
				MaxBodyBytes: c.maxBody,
				Models: map[string]config.Model{
					"m": {URL: backend.URL, Headers: c.headers},
				},
			}
			h, err := New(cfg)
			if err != nil {
				t.Fatal(err)
			}
			rec := post(t, h, c.body, c.authHeader)
			if rec.Code != c.wantCode {
				t.Fatalf("got status %d, want %d", rec.Code, c.wantCode)
			}
			if c.wantBody != "" && rec.Body.String() != c.wantBody {
				t.Fatalf("got body %q, want %q", rec.Body.String(), c.wantBody)
			}
			if c.checkFwd != nil {
				c.checkFwd(t, captured)
			}
		})
	}
}

func TestProxyPreservesHostAndQuery(t *testing.T) {
	backend, captured := newBackend(t)
	h, err := New(&config.Config{Models: map[string]config.Model{
		"m": {URL: backend.URL + "/base?backend=1"},
	}})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions?valid=1&semi=one;two", strings.NewReader(`{"model":"m"}`))
	req.Host = "client.example"
	req.RemoteAddr = "198.51.100.4:4321"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	if captured.host != req.Host {
		t.Errorf("backend saw host %q, want %q", captured.host, req.Host)
	}

	if captured.path != "/base/v1/chat/completions" {
		t.Errorf("backend saw path %q", captured.path)
	}

	if captured.query != "backend=1&valid=1&semi=one;two" {
		t.Errorf("backend saw query %q", captured.query)
	}

	if got := captured.header.Get("X-Forwarded-For"); got != "198.51.100.4" {
		t.Errorf("backend saw X-Forwarded-For %q", got)
	}
}

func TestModelField(t *testing.T) {
	backend, captured := newBackend(t)
	h, err := New(&config.Config{Models: map[string]config.Model{
		"a": {URL: backend.URL},
	}})
	if err != nil {
		t.Fatal(err)
	}

	for _, body := range []string{
		`{"model":"a","prompt":{"model":"b"}}`,
	} {
		if rec := post(t, h, body, ""); rec.Code != http.StatusOK {
			t.Fatalf("body %s: got status %d", body, rec.Code)
		}

		if captured.body != body {
			t.Fatalf("backend saw body %q, want %q", captured.body, body)
		}
	}

	for _, body := range []string{`{}`, `{"model":123}`, `{"model":"a","model":null}`} {
		if rec := post(t, h, body, ""); rec.Code != http.StatusBadRequest {
			t.Fatalf("body %s: got status %d", body, rec.Code)
		}
	}
}

func TestProxyPreservesRequestTrailer(t *testing.T) {
	var trailer string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.Copy(io.Discard, req.Body)
		trailer = req.Trailer.Get("X-Check")
	}))
	t.Cleanup(backend.Close)

	h, err := New(&config.Config{Models: map[string]config.Model{"m": {URL: backend.URL}}})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.ContentLength = -1
	req.Trailer = http.Header{"X-Check": {"ok"}}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || trailer != "ok" {
		t.Fatalf("status %d, trailer %q", rec.Code, trailer)
	}
}

func TestBodyLimit(t *testing.T) {
	cases := []struct {
		name          string
		maxBytes      int64
		contentLength int64
		body          io.Reader
		wantCode      int
	}{
		{"known length is rejected before reading", 4, 5, iotest.ErrReader(errors.New("body was read")), http.StatusRequestEntityTooLarge},
		{"unknown length is capped while reading", 4, -1, strings.NewReader(`{"model":"m"}`), http.StatusRequestEntityTooLarge},
		{"zero disables the body limit", 0, 13, strings.NewReader(`{"model":"m"}`), http.StatusNotFound},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/", c.body)
			req.ContentLength = c.contentLength
			rec := httptest.NewRecorder()
			proxyHandler(nil, c.maxBytes, 0)(rec, req)

			if rec.Code != c.wantCode {
				t.Fatalf("got status %d, want %d", rec.Code, c.wantCode)
			}
		})
	}
}

func TestConcurrentRequestLimit(t *testing.T) {
	handler := proxyHandler(nil, 0, 1)
	body, writer := io.Pipe()
	done := make(chan struct{})

	go func() {
		handler(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", body))
		close(done)
	}()

	// Returns once the first request holds its slot and reads the body.
	if _, err := writer.Write([]byte("{")); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader("{}")))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got status %d, want 503", rec.Code)
	}

	_ = writer.Close()
	<-done
}

func TestUnlistedModel(t *testing.T) {
	backend, captured := newBackend(t)
	h, err := New(&config.Config{Models: map[string]config.Model{
		"chat":     {URL: backend.URL},
		"detector": {URL: backend.URL, Unlisted: true},
	}})
	if err != nil {
		t.Fatal(err)
	}

	t.Run("routes like any other backend", func(t *testing.T) {
		rec := post(t, h, `{"model":"detector","text":"candidate"}`, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("got status %d", rec.Code)
		}
		if captured.body != `{"model":"detector","text":"candidate"}` {
			t.Fatalf("got body %q", captured.body)
		}
	})

	t.Run("hidden from list, retrieve and health", func(t *testing.T) {
		var got modelList
		if err := json.Unmarshal(get(t, h, "/v1/models", "").Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if len(got.Data) != 1 || got.Data[0].ID != "chat" {
			t.Fatalf("got catalog %+v", got.Data)
		}

		if rec := get(t, h, "/v1/models/detector", ""); rec.Code != http.StatusNotFound {
			t.Fatalf("got status %d", rec.Code)
		}

		var h2 health
		if err := json.Unmarshal(get(t, h, "/health", "").Body.Bytes(), &h2); err != nil {
			t.Fatal(err)
		}
		if h2.Models != 1 {
			t.Fatalf("got %d models", h2.Models)
		}
	})
}
