package router

import (
	"encoding/json/jsontext"
	"encoding/json/v2"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
)

type capturedRequest struct {
	body   string
	header http.Header
	host   string
	path   string
	query  string
}

func startBackend(t *testing.T) (*httptest.Server, *capturedRequest) {
	t.Helper()
	captured := &capturedRequest{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		captured.body = string(body)
		captured.header = r.Header.Clone()
		captured.host = r.Host
		captured.path = r.URL.Path
		captured.query = r.URL.RawQuery
		_, _ = w.Write([]byte("backend ok"))
	}))
	t.Cleanup(srv.Close)

	return srv, captured
}

func newRouter(t *testing.T, cfg *config.Config) http.Handler {
	t.Helper()
	h, err := New(cfg, &Limits{})
	if err != nil {
		t.Fatal(err)
	}

	h.Start()
	t.Cleanup(h.Close)

	return h
}

func send(t *testing.T, handler http.Handler, method, path, body, authHeader string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))

	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	return rec
}

func TestCatalog(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {KeyHash: apikey.Of("llmhop_t-secret")}}, Models: map[string]config.Model{
		"b":        {URLs: []string{backend.URL}},
		"a":        {URLs: []string{backend.URL}},
		"detector": {URLs: []string{backend.URL}, Unlisted: true},
		"openai/*": {URLs: []string{backend.URL}, Aliases: map[string]config.Alias{"c": {}}},
	}})

	t.Run("health needs no token and counts listed models", func(t *testing.T) {
		var got health
		if err := json.Unmarshal(send(t, h, http.MethodGet, "/llmhop/health", "", "").Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if got.Status != "ok" || got.Models != 3 {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("list is sorted and omits unlisted models and wildcards", func(t *testing.T) {
		var got struct {
			Data []modelObject `json:"data"`
		}
		if err := json.Unmarshal(send(t, h, http.MethodGet, "/v1/models", "", "Bearer llmhop_t-secret").Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		ids := make([]string, len(got.Data))
		for i, obj := range got.Data {
			ids[i] = string(obj["id"])
		}

		if !slices.Equal(ids, []string{`"a"`, `"b"`, `"c"`}) {
			t.Fatalf("got models %+v", got.Data)
		}
	})

	t.Run("retrieve", func(t *testing.T) {
		for _, name := range []string{"a", "c"} {
			if rec := send(t, h, http.MethodGet, "/v1/models/"+name, "", "Bearer llmhop_t-secret"); rec.Code != http.StatusOK {
				t.Fatalf("%s got status %d", name, rec.Code)
			}
		}

		if rec := send(t, h, http.MethodGet, "/v1/models/detector", "", "Bearer llmhop_t-secret"); rec.Code != http.StatusNotFound {
			t.Fatalf("got status %d", rec.Code)
		}
	})

	t.Run("requires a token", func(t *testing.T) {
		rec := send(t, h, http.MethodGet, "/v1/models", "", "")

		var got apiError
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if rec.Code != http.StatusUnauthorized || rec.Header().Get("WWW-Authenticate") != "Bearer" || got.Error.Type != "authentication_error" {
			t.Fatalf("got status %d, header %v, error %+v", rec.Code, rec.Header(), got)
		}
	})
}

func TestRouterRequests(t *testing.T) {
	cases := []struct {
		name       string
		auth       map[string]config.Client
		headers    map[string]string
		body       string
		authHeader string
		maxBody    int64
		wantCode   int
		checkFwd   func(t *testing.T, req *capturedRequest)
	}{
		{name: "invalid JSON", body: `{"model":`, wantCode: http.StatusBadRequest},
		{name: "missing model", body: `{}`, wantCode: http.StatusBadRequest},
		{name: "null model", body: `{"model":null}`, wantCode: http.StatusBadRequest},
		{name: "non-string model", body: `{"model":123}`, wantCode: http.StatusBadRequest},
		{name: "duplicate model key", body: `{"model":"m","model":null}`, wantCode: http.StatusBadRequest},
		{name: "unknown model", body: `{"model": "nope"}`, wantCode: http.StatusNotFound},
		{name: "auth runs before model lookup", auth: map[string]config.Client{"t": {KeyHash: apikey.Of("llmhop_t-secret")}}, body: `{"model": "unknown"}`, wantCode: http.StatusUnauthorized},
		{name: "oversized body", maxBody: 16, body: `{"model": "m", "prompt": "` + strings.Repeat("x", 100) + `"}`, wantCode: http.StatusRequestEntityTooLarge},
		{
			name:     "known model is proxied with its body intact",
			body:     `{"model":"m","prompt":{"model":"b"}}`,
			wantCode: http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if r.body != `{"model":"m","prompt":{"model":"b"}}` {
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
			name:       "auth strips client Authorization before forwarding",
			auth:       map[string]config.Client{"t": {KeyHash: apikey.Of("llmhop_t-secret")}},
			body:       `{"model": "m"}`,
			authHeader: "Bearer llmhop_t-secret",
			wantCode:   http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if got := r.header.Get("Authorization"); got != "" {
					t.Fatalf("backend saw Authorization %q, want stripped", got)
				}
			},
		},
		{
			name:       "model headers are injected",
			headers:    map[string]string{"Authorization": "Bearer upstream", "Host": "backend.example"},
			body:       `{"model": "m"}`,
			authHeader: "Bearer client-token",
			wantCode:   http.StatusOK,
			checkFwd: func(t *testing.T, r *capturedRequest) {
				if got := r.header.Get("Authorization"); got != "Bearer upstream" {
					t.Fatalf("got Authorization %q", got)
				}

				if r.host != "backend.example" {
					t.Fatalf("backend saw host %q", r.host)
				}
			},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			backend, captured := startBackend(t)
			h := newRouter(t, &config.Config{
				Clients:      c.auth,
				MaxBodyBytes: c.maxBody,
				Models:       map[string]config.Model{"m": {URLs: []string{backend.URL}, Headers: c.headers}},
			})
			rec := send(t, h, http.MethodPost, "/", c.body, c.authHeader)

			if rec.Code != c.wantCode {
				t.Fatalf("got status %d, want %d", rec.Code, c.wantCode)
			}

			if c.checkFwd != nil {
				c.checkFwd(t, captured)
			}
		})
	}
}

func TestProxyPreservesHostAndQuery(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"m": {URLs: []string{backend.URL + "/base?backend=1"}},
	}})

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions?valid=1&semi=one;two", strings.NewReader(`{"model":"m"}`))
	req.Host = "client.example"
	req.RemoteAddr = "198.51.100.4:4321"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	if captured.host != req.Host || captured.path != "/base/v1/chat/completions" || captured.query != "backend=1&valid=1&semi=one;two" {
		t.Errorf("backend saw %+v", captured)
	}

	if got := captured.header.Get("X-Forwarded-For"); got != "198.51.100.4" {
		t.Errorf("backend saw X-Forwarded-For %q", got)
	}
}

func TestPathRouting(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {KeyHash: apikey.Of("llmhop_t-secret")}}, Models: map[string]config.Model{
		"detector": {URLs: []string{backend.URL + "/base"}, Unlisted: true},
	}})

	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/detector/detect?x=1", `{"text":"candidate"}`, "Bearer llmhop_t-secret"); rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	if captured.path != "/base/detect" || captured.query != "x=1" || captured.body != `{"text":"candidate"}` {
		t.Fatalf("backend saw %+v", captured)
	}

	for _, path := range []string{"/llmhop/proxy/nope/detect", "/llmhop/models/detector/proxy/detect"} {
		if rec := send(t, h, http.MethodPost, path, "", "Bearer llmhop_t-secret"); rec.Code != http.StatusNotFound {
			t.Fatalf("%s got status %d", path, rec.Code)
		}
	}
}

func TestSlashModelNames(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"org/name": {URLs: []string{backend.URL}},
		"org":      {URLs: []string{backend.URL + "/short"}},
	}})

	if rec := send(t, h, http.MethodGet, "/v1/models/org/name", "", ""); rec.Code != http.StatusOK {
		t.Fatalf("retrieve got status %d", rec.Code)
	}

	for _, path := range []string{"/llmhop/proxy/org/name/a%2Fb?x=1", "/llmhop/proxy/org%2Fname/a%2Fb?x=1"} {
		if rec := send(t, h, http.MethodPost, path, "{}", ""); rec.Code != http.StatusOK {
			t.Fatalf("%s got status %d", path, rec.Code)
		}

		if captured.path != "/a/b" || captured.query != "x=1" {
			t.Fatalf("%s: backend saw %+v", path, captured)
		}
	}

	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/org/other", "{}", ""); rec.Code != http.StatusOK || captured.path != "/short/other" {
		t.Fatalf("shorter name got status %d, backend saw %+v", rec.Code, captured)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"org/name"}`, ""); rec.Code != http.StatusOK {
		t.Fatalf("body routing got status %d", rec.Code)
	}
}

func TestProxyPreservesRequestTrailer(t *testing.T) {
	var trailer string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.Copy(io.Discard, req.Body)
		trailer = req.Trailer.Get("X-Check")
	}))
	t.Cleanup(srv.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{srv.URL}}}})

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.ContentLength = -1
	req.Trailer = http.Header{"X-Check": {"ok"}}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || trailer != "ok" {
		t.Fatalf("status %d, trailer %q", rec.Code, trailer)
	}
}

func TestNames(t *testing.T) {
	base, captured := startBackend(t)
	remote, remoteCaptured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"base": {
			URLs:     []string{base.URL},
			Aliases:  map[string]config.Alias{"base:lora": {}, "sql": {Model: "base:sql"}},
			Metadata: map[string]jsontext.Value{"max_model_len": jsontext.Value("4096")},
		},
		"openai/*": {URLs: []string{remote.URL}},
	}})

	var got struct {
		Data []modelObject `json:"data"`
	}
	if err := json.Unmarshal(send(t, h, http.MethodGet, "/v1/models", "", "").Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}

	if len(got.Data) != 3 || string(got.Data[1]["id"]) != `"base:lora"` || string(got.Data[1]["max_model_len"]) != "4096" {
		t.Fatalf("got models %v", got.Data)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"base:lora"}`, ""); rec.Code != http.StatusOK || captured.body != `{"model":"base:lora"}` {
		t.Fatalf("alias got status %d, backend saw %+v", rec.Code, captured)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"n": {"model": 1}, "model" : "sql", "x": 2}`, ""); rec.Code != http.StatusOK || captured.body != `{"n": {"model": 1}, "model" : "base:sql", "x": 2}` {
		t.Fatalf("rewriting alias got status %d, backend saw %+v", rec.Code, captured)
	}

	var form strings.Builder
	writer := multipart.NewWriter(&form)
	_ = writer.WriteField("model", "sql")
	_ = writer.Close()
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(form.String()))
	req.Header.Set("Content-Type", writer.FormDataContentType())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("multipart body of a rewriting alias got status %d", rec.Code)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"openai/gpt-5"}`, ""); rec.Code != http.StatusOK || remoteCaptured.body != `{"model":"openai/gpt-5"}` {
		t.Fatalf("wildcard got status %d, backend saw %+v", rec.Code, remoteCaptured)
	}

	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/openai/gpt-5/x", "", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("path-routed wildcard got status %d", rec.Code)
	}
}

// Informational responses keep the request ID of the final one.
func TestEarlyHintsKeepHeaders(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Link", "</style.css>; rel=preload")
		w.WriteHeader(http.StatusEarlyHints)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(backend.Close)
	gateway := httptest.NewServer(newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{backend.URL}}}}))
	t.Cleanup(gateway.Close)

	req, _ := http.NewRequest(http.MethodPost, gateway.URL, strings.NewReader(`{"model":"m"}`))
	req.Header.Set(requestIDHeader, "r1")

	resp, err := gateway.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}

	_ = resp.Body.Close()

	if resp.StatusCode != http.StatusOK || resp.Header.Get(requestIDHeader) != "r1" {
		t.Fatalf("got status %d and headers %v", resp.StatusCode, resp.Header)
	}
}
