package router

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/config"
)

type capturedRequest struct {
	method string
	body   string
	header http.Header
}

func newBackend(t *testing.T) (*httptest.Server, *capturedRequest) {
	t.Helper()
	captured := &capturedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		captured.method = r.Method
		captured.body = string(body)
		captured.header = r.Header.Clone()
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
			headers: map[string]string{"Authorization": "Bearer upstream", "X-Injected": "yes"},
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
