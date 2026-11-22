package router

import (
	"context"
	"crypto/sha256"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"io"
	"maps"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"testing/iotest"
	"time"

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

func TestBearer(t *testing.T) {
	a := &authenticator{keys: map[[sha256.Size]byte]*client{
		sha256.Sum256([]byte("alpha")): {name: "a"},
		sha256.Sum256([]byte("beta")):  {name: "b"},
	}}
	cases := []struct {
		header string
		want   string
	}{
		{"Bearer beta", "b"},
		{"bearer alpha", "a"},
		{"Bearer alph", ""},
		{"Basic alpha", ""},
		{"alpha", ""},
	}

	for _, c := range cases {
		got := ""
		if token, ok := bearer(c.header); ok {
			if c, ok := a.lookup(token); ok {
				got = c.name
			}
		}

		if got != c.want {
			t.Errorf("header %q named %q, want %q", c.header, got, c.want)
		}
	}
}

func TestCatalog(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {Key: "secret"}}, Models: map[string]config.Model{
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
		if err := json.Unmarshal(send(t, h, http.MethodGet, "/v1/models", "", "Bearer secret").Body.Bytes(), &got); err != nil {
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
			if rec := send(t, h, http.MethodGet, "/v1/models/"+name, "", "Bearer secret"); rec.Code != http.StatusOK {
				t.Fatalf("%s got status %d", name, rec.Code)
			}
		}

		if rec := send(t, h, http.MethodGet, "/v1/models/detector", "", "Bearer secret"); rec.Code != http.StatusNotFound {
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
		{name: "auth runs before model lookup", auth: map[string]config.Client{"t": {Key: "secret"}}, body: `{"model": "unknown"}`, wantCode: http.StatusUnauthorized},
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
			auth:       map[string]config.Client{"t": {Key: "secret"}},
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

// Client credentials without any credential lock the gateway instead of
// opening it.
func TestAuthRequiredWithoutTokens(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		ClientCredentials: true,
		Models:            map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	if rec := send(t, h, http.MethodPost, "/", `{"model": "m"}`, "Bearer anything"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want %d", rec.Code, http.StatusUnauthorized)
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
	h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {Key: "secret"}}, Models: map[string]config.Model{
		"detector": {URLs: []string{backend.URL + "/base"}, Unlisted: true},
	}})

	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/detector/detect?x=1", `{"text":"candidate"}`, "Bearer secret"); rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	if captured.path != "/base/detect" || captured.query != "x=1" || captured.body != `{"text":"candidate"}` {
		t.Fatalf("backend saw %+v", captured)
	}

	for _, path := range []string{"/llmhop/proxy/nope/detect", "/llmhop/models/detector/proxy/detect"} {
		if rec := send(t, h, http.MethodPost, path, "", "Bearer secret"); rec.Code != http.StatusNotFound {
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
			h := newRouter(t, &config.Config{MaxBodyBytes: c.maxBytes, Models: map[string]config.Model{"other": {URLs: []string{"http://127.0.0.1:1"}}}})
			req := httptest.NewRequest(http.MethodPost, "/", c.body)
			req.ContentLength = c.contentLength
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != c.wantCode {
				t.Fatalf("got status %d, want %d", rec.Code, c.wantCode)
			}
		})
	}
}

func TestConcurrentRequestLimit(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)
	fast, _ := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"a": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1},
		"b": {URLs: []string{fast.URL}, MaxConcurrentRequests: 1},
	}})

	done := make(chan struct{})

	go func() {
		send(t, h, http.MethodPost, "/", `{"model":"a"}`, "")
		close(done)
	}()

	// Returns once the first request holds the only slot of model a.
	<-entered

	if rec := send(t, h, http.MethodPost, "/", `{"model":"a"}`, ""); rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "1" {
		t.Errorf("saturated model got status %d, want 429", rec.Code)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"b"}`, ""); rec.Code != http.StatusOK {
		t.Errorf("other model got status %d, want 200", rec.Code)
	}

	close(release)
	<-done
}

func TestReadiness(t *testing.T) {
	// Healthy only at /health with the injected header and the Host the proxy
	// would send, the configured one over TCP and localhost over a socket.
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" || r.Header.Get("X-Key") != "k" || r.Host != "probe.example" && r.Host != "localhost" {
			w.WriteHeader(http.StatusInternalServerError)
		}
	})
	tcp := httptest.NewServer(handler)
	t.Cleanup(tcp.Close)

	socket := filepath.Join(t.TempDir(), "h.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}

	unix := httptest.NewUnstartedServer(handler)
	_ = unix.Listener.Close()
	unix.Listener = ln
	unix.Start()
	t.Cleanup(unix.Close)

	models := map[string]config.Model{
		"tcp":      {URLs: []string{tcp.URL}, HealthPath: "/health", Headers: map[string]string{"X-Key": "k", "Host": "probe.example"}},
		"unix":     {URLs: []string{"unix://" + socket}, HealthPath: "/health", Headers: map[string]string{"X-Key": "k"}},
		"unprobed": {URLs: []string{tcp.URL}},
	}

	check := func(wantCode int, want readiness) {
		t.Helper()
		h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {Key: "secret"}}, Models: models})
		rec := send(t, h, http.MethodGet, "/llmhop/readiness", "", "")

		var got readiness
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if rec.Code != wantCode || got != want {
			t.Errorf("got status %d and %+v, want %d and %+v", rec.Code, got, wantCode, want)
		}
	}

	check(http.StatusOK, readiness{Status: "ok", Ready: 2, Probed: 2})
	// One answering server keeps a model ready.
	models["replicas"] = config.Model{URLs: []string{"unix://" + filepath.Join(t.TempDir(), "down.sock"), tcp.URL}, HealthPath: "/health", Headers: map[string]string{"Host": "probe.example", "X-Key": "k"}}
	check(http.StatusOK, readiness{Status: "ok", Ready: 3, Probed: 3})

	models["broken"] = config.Model{URLs: []string{tcp.URL}, HealthPath: "/missing"}
	check(http.StatusServiceUnavailable, readiness{Status: "unavailable", Ready: 3, Probed: 4})
}

func TestBufferedBytesLimit(t *testing.T) {
	srv, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedBytes: 16,
		Models:           map[string]config.Model{"m": {URLs: []string{srv.URL}}},
	})

	// The first body arrives slowly, so its partial body holds 10 bytes.
	body, writer := io.Pipe()
	done := make(chan struct{})

	go func() {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", body))
		close(done)
	}()

	// The second write returns only once the router reads again, so the first is charged.
	for _, chunk := range []string{`{"model":`, " "} {
		if _, err := writer.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("buffered request got status %d, want 503", rec.Code)
	}

	// Path-routed bodies stream, so they need no budget.
	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/m/", "{}", ""); rec.Code != http.StatusOK {
		t.Errorf("streamed request got status %d, want 200", rec.Code)
	}

	_ = writer.CloseWithError(io.ErrUnexpectedEOF)
	<-done

	// The failed read released its bytes.
	for range 2 {
		if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusOK {
			t.Errorf("buffered request got status %d, want 200", rec.Code)
		}
	}
}

func TestBufferedBytesReleasedOnceResponding(t *testing.T) {
	unblock := make(chan struct{})
	streaming := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
		_ = http.NewResponseController(w).Flush()
		<-unblock
	}))
	t.Cleanup(streaming.Close)
	fast, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedBytes: 16,
		Models:           map[string]config.Model{"slow": {URLs: []string{streaming.URL}}, "fast": {URLs: []string{fast.URL}}},
	})

	// The router's own hook, which releases the bytes, runs before this outer one.
	sent, done := make(chan struct{}), make(chan struct{})
	ctx := httptrace.WithClientTrace(t.Context(), &httptrace.ClientTrace{
		GotFirstResponseByte: func() { close(sent) },
	})

	go func() {
		req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/", strings.NewReader(`{"model":"slow"}`))
		h.ServeHTTP(httptest.NewRecorder(), req)
		close(done)
	}()

	<-sent

	// The slow response still streams, but its body can no longer be resent.
	if rec := send(t, h, http.MethodPost, "/", `{"model":"fast"}`, ""); rec.Code != http.StatusOK {
		t.Errorf("buffered request got status %d, want 200", rec.Code)
	}

	close(unblock)
	<-done
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

func TestBufferedIdempotentRetry(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)

		// The second request reuses the connection, which closes before any response.
		if calls.Add(1) == 2 {
			conn, _, _ := http.NewResponseController(w).Hijack()
			_ = conn.Close()
		}
	}))
	t.Cleanup(srv.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{srv.URL}}}})

	for range 2 {
		req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
		req.Header.Set("Idempotency-Key", "k")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("idempotent request got status %d, want 200", rec.Code)
		}
	}

	if n := calls.Load(); n != 3 {
		t.Errorf("backend got %d requests, want 3", n)
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

func TestMultipartModel(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"whisper": {URLs: []string{backend.URL}}}})

	var body strings.Builder
	form := multipart.NewWriter(&body)
	_ = form.WriteField("model", "whisper")
	_ = form.Close()

	req := httptest.NewRequest(http.MethodPost, "/v1/audio/transcriptions", strings.NewReader(body.String()))
	req.Header.Set("Content-Type", form.FormDataContentType())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || captured.body != body.String() {
		t.Fatalf("got status %d, backend saw %q", rec.Code, captured.body)
	}

	// The backend would read another model than the one routed by.
	body.Reset()
	form = multipart.NewWriter(&body)
	_ = form.WriteField("model", "whisper")
	_ = form.WriteField("model", "other")
	_ = form.Close()

	req = httptest.NewRequest(http.MethodPost, "/v1/audio/transcriptions", strings.NewReader(body.String()))
	req.Header.Set("Content-Type", form.FormDataContentType())
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("duplicate model got status %d", rec.Code)
	}
}

// Turns of one conversation stick to a server.
func TestAffinity(t *testing.T) {
	var hits [2]atomic.Int32
	servers := make([]string, 2)

	for i := range servers {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits[i].Add(1)
			_, _ = io.Copy(io.Discard, r.Body)
		}))
		t.Cleanup(srv.Close)
		servers[i] = srv.URL
	}

	h := newRouter(t, &config.Config{Affinity: config.DefaultAffinity, Models: map[string]config.Model{
		"m": {URLs: servers},
	}})

	for range 6 {
		if rec := send(t, h, http.MethodPost, "/", `{"model":"m","prompt_cache_key":"c"}`, ""); rec.Code != http.StatusOK {
			t.Fatalf("got status %d", rec.Code)
		}
	}

	if a, b := hits[0].Load(), hits[1].Load(); a+b != 6 || a != 0 && b != 0 {
		t.Fatalf("servers got %d and %d requests, want all on one", a, b)
	}
}

// A refused connection fails over to the next server. A keyless request
// takes the first of equally idle servers, so it tries the dead one first.
func TestFailover(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"m": {URLs: []string{"unix://" + filepath.Join(t.TempDir(), "down.sock"), backend.URL}},
	}})

	body := `{"model":"m"}`
	if rec := send(t, h, http.MethodPost, "/", body, ""); rec.Code != http.StatusOK || captured.body != body {
		t.Fatalf("got status %d, backend saw %q", rec.Code, captured.body)
	}
}



func TestDataParallelRanks(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{
		Affinity: []string{"header:X-Session-Id"},
		Models: map[string]config.Model{
			"m": {URLs: []string{backend.URL}, DataParallelSize: 2},
			"u": {URLs: []string{backend.URL}},
		},
	})

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.Header.Set("X-Session-Id", "s")
	h.ServeHTTP(httptest.NewRecorder(), req)

	if rank := captured.header.Get(rankHeader); rank != "0" && rank != "1" {
		t.Fatalf("keyed request got rank %q", rank)
	}

	// The server balances keyless requests over its ranks itself, which a
	// client cannot pin either.
	req = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.Header.Set(rankHeader, "7")
	h.ServeHTTP(httptest.NewRecorder(), req)

	if rank := captured.header.Get(rankHeader); rank != "" {
		t.Fatalf("keyless request got rank %q", rank)
	}

	// Nor can it pin one on a model without ranks.
	req = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"u"}`))
	req.Header.Set(rankHeader, "7")
	h.ServeHTTP(httptest.NewRecorder(), req)

	if rank := captured.header.Get(rankHeader); rank != "" {
		t.Fatalf("unranked model got rank %q", rank)
	}
}

func TestQueueAndResponseTimeout(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"m": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1, QueueTimeoutSeconds: 10, ResponseTimeoutSeconds: 1},
	}})

	first := make(chan int)

	go func() { first <- send(t, h, http.MethodPost, "/", `{"model":"m"}`, "").Code }()

	<-entered

	// The second request waits for the slot of the first, which times out.
	second := make(chan int)

	go func() { second <- send(t, h, http.MethodPost, "/", `{"model":"m"}`, "").Code }()

	if code := <-first; code != http.StatusGatewayTimeout {
		t.Errorf("first request got status %d, want 504", code)
	}

	<-entered
	release <- struct{}{}
	close(release)

	if code := <-second; code != http.StatusOK && code != http.StatusGatewayTimeout {
		t.Errorf("queued request got status %d", code)
	}
}

func TestClientHeaders(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(requestIDHeader, r.Header.Get(requestIDHeader))
		_, _ = w.Write([]byte(r.Header.Get(clientHeader) + " " + r.Header.Get(requestIDHeader)))
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Clients: map[string]config.Client{"alice": {Key: "secret"}},
		Models:  map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set(requestIDHeader, "r1")
	req.Header.Set(clientHeader, "mallory")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if ids := rec.Header().Values(requestIDHeader); rec.Body.String() != "alice r1" || len(ids) != 1 || ids[0] != "r1" {
		t.Errorf("backend saw %q, response IDs %q", rec.Body.String(), ids)
	}
}

func TestAffinityOf(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("X-Session-Id", "s")
	key := func(sources []string, body string) affinity { return affinityOf(req, sources, []byte(body)) }

	if a, b := key(config.DefaultAffinity, `{"prompt_cache_key":"k"}`), key([]string{"prompt_cache_key"}, `{"prompt_cache_key":"k"}`); !a.keyed || !b.keyed || a.key == b.key {
		t.Errorf("the header did not take precedence: %+v, %+v", a, b)
	}

	if a := key([]string{"prompt_cache_key"}, `{"messages":[]}`); a.keyed {
		t.Errorf("keyless body got %+v", a)
	}
}

// A reload shares the limits, so requests of the previous router count.
func TestLimitsSharedAcrossRouters(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)

	limits := &Limits{}
	cfg := &config.Config{Models: map[string]config.Model{"m": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1}}}

	old, err := New(cfg, limits)
	if err != nil {
		t.Fatal(err)
	}

	reloaded, err := New(cfg, limits)
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})

	go func() {
		send(t, old, http.MethodPost, "/", `{"model":"m"}`, "")
		close(done)
	}()

	<-entered

	if rec := send(t, reloaded, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusTooManyRequests {
		t.Errorf("reloaded router got status %d, want 429", rec.Code)
	}

	close(release)
	<-done
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

func TestTrustedSockets(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_, _ = w.Write([]byte(r.Header.Get(clientHeader)))
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Clients:     map[string]config.Client{"alice": {Key: "secret"}, "ssh": {Listener: "ssh"}},
		CORSOrigins: []string{"*"},
		Models:      map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	cases := []struct {
		name, listener, host string
		header               http.Header
		want                 int
	}{
		{"client listener", "ssh", "localhost:8080", nil, http.StatusOK},
		{"other listener", "default", "localhost:8080", nil, http.StatusUnauthorized},
		{"rebound host", "ssh", "evil.example:8080", nil, http.StatusForbidden},
		{"cross-site request", "ssh", "localhost:8080", http.Header{"Sec-Fetch-Site": {"cross-site"}}, http.StatusForbidden},
		{"same-origin page", "ssh", "127.0.0.1:8080", http.Header{"Origin": {"http://127.0.0.1:8080"}}, http.StatusOK},
	}

	for _, c := range cases {
		req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
		req = req.WithContext(context.WithValue(WithListener(req.Context(), c.listener), http.LocalAddrContextKey, &net.UnixAddr{Name: "/run/llmhop.sock", Net: "unix"}))
		req.Host = c.host
		maps.Copy(req.Header, c.header)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != c.want || c.want == http.StatusOK && rec.Body.String() != "ssh" {
			t.Errorf("%s: got status %d and body %q", c.name, rec.Code, rec.Body.String())
		}

		// The backend's CORS header never reaches a page.
		if rec.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("%s: got CORS headers %v", c.name, rec.Header())
		}
	}
}

func TestCORS(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		Clients:     map[string]config.Client{"alice": {Key: "secret"}},
		CORSOrigins: []string{"https://chat.example"},
		Models:      map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	preflight := http.Header{"Access-Control-Request-Method": {"POST"}, "Access-Control-Request-Headers": {"authorization,content-type"}}
	token := http.Header{"Authorization": {"Bearer secret"}}

	cases := []struct {
		name, method, origin string
		header               http.Header
		status               int
		allowed              string
	}{
		{"preflight", http.MethodOptions, "https://chat.example", preflight, http.StatusNoContent, "https://chat.example"},
		{"request", http.MethodPost, "https://chat.example", token, http.StatusOK, "https://chat.example"},
		{"request without token", http.MethodPost, "https://chat.example", nil, http.StatusUnauthorized, "https://chat.example"},
		{"preflight of another origin", http.MethodOptions, "https://evil.example", preflight, http.StatusNoContent, ""},
	}

	for _, c := range cases {
		req := httptest.NewRequest(c.method, "/v1/chat/completions", strings.NewReader(`{"model":"m"}`))
		req.Header.Set("Origin", c.origin)
		maps.Copy(req.Header, c.header)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != c.status || rec.Header().Get("Access-Control-Allow-Origin") != c.allowed || rec.Header().Get("Access-Control-Allow-Credentials") != "" {
			t.Errorf("%s: got status %d and headers %v", c.name, rec.Code, rec.Header())
		}
	}
}
