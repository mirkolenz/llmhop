package router

import (
	"context"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"io"
	"maps"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"testing/iotest"
	"time"

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

// A token names the client of its hash, only in the Bearer scheme.
func TestBearer(t *testing.T) {
	a := newAuthenticator(&config.Config{Clients: map[string]config.Client{
		"a": {KeyHash: apikey.Of("llmhop_alpha")},
		"b": {KeyHash: apikey.Of("llmhop_beta")},
	}}, &Limits{})
	cases := []struct {
		header string
		want   string
	}{
		{"Bearer llmhop_beta", "b"},
		{"bearer llmhop_alpha", "a"},
		{"Bearer llmhop_alph", ""},
		{"Basic llmhop_alpha", ""},
		{"llmhop_alpha", ""},
	}

	for _, c := range cases {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set("Authorization", c.header)

		got := ""
		if cl := a.bearerClient(req); cl != nil {
			got = cl.name
		}

		if got != c.want {
			t.Errorf("header %q named %q, want %q", c.header, got, c.want)
		}
	}
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
		h := newRouter(t, &config.Config{Clients: map[string]config.Client{"t": {KeyHash: apikey.Of("llmhop_t-secret")}}, Models: models})
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

// Closing a router before its first probes unblocks its readiness.
func TestReadinessUnblockedByClose(t *testing.T) {
	hang := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-hang }))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(hang) })

	rt, err := New(&config.Config{Models: map[string]config.Model{"m": {URLs: []string{srv.URL}, HealthPath: "/health"}}}, &Limits{})
	if err != nil {
		t.Fatal(err)
	}

	rt.Start()
	rt.Close()
	send(t, rt, http.MethodGet, "/llmhop/readiness", "", "")
}

// A reload changing the health path probes the new one before readiness.
func TestReloadedHealthPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}))
	t.Cleanup(srv.Close)

	limits := &Limits{}

	for _, c := range []struct {
		path string
		want int
	}{{"/health", http.StatusOK}, {"/missing", http.StatusServiceUnavailable}} {
		rt, err := New(&config.Config{Models: map[string]config.Model{"m": {URLs: []string{srv.URL}, HealthPath: c.path}}}, limits)
		if err != nil {
			t.Fatal(err)
		}

		rt.Start()
		t.Cleanup(rt.Close)

		if rec := send(t, rt, http.MethodGet, "/llmhop/readiness", "", ""); rec.Code != c.want {
			t.Errorf("%s: got status %d, want %d", c.path, rec.Code, c.want)
		}
	}
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

	// The router releases the bytes once it accepts the response, before it
	// writes the header.
	rec, done := &headerSignal{httptest.NewRecorder(), make(chan struct{})}, make(chan struct{})

	go func() {
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"slow"}`)))
		close(done)
	}()

	<-rec.wrote

	// The slow response still streams, but its body can no longer be resent.
	if rec := send(t, h, http.MethodPost, "/", `{"model":"fast"}`, ""); rec.Code != http.StatusOK {
		t.Errorf("buffered request got status %d, want 200", rec.Code)
	}

	close(unblock)
	<-done
}

// headerSignal closes wrote once the header is written.
type headerSignal struct {
	*httptest.ResponseRecorder
	wrote chan struct{}
}

func (h *headerSignal) WriteHeader(code int) {
	h.ResponseRecorder.WriteHeader(code)
	close(h.wrote)
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

// statusBackends starts servers answering a status each, and counts the
// requests of each.
func statusBackends(t *testing.T, statuses ...int) ([]string, []atomic.Int32) {
	t.Helper()
	urls, hits := make([]string, len(statuses)), make([]atomic.Int32, len(statuses))

	for i, status := range statuses {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodPost {
				hits[i].Add(1)
			}

			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(status)
		}))
		t.Cleanup(srv.Close)
		urls[i] = srv.URL
	}

	return urls, hits
}

// A 503 moves a buffered request on to the next server.
func TestRetryUnavailable(t *testing.T) {
	urls, hits := statusBackends(t, http.StatusServiceUnavailable, http.StatusOK)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: urls}}})

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusOK || hits[0].Load() != 1 || hits[1].Load() != 1 {
		t.Fatalf("got status %d after %d and %d requests", rec.Code, hits[0].Load(), hits[1].Load())
	}
}

// Three 503 in a row eject a server, each retried on the next one, while a
// 429 or 500, which may concern the request alone, never does. Keyless
// requests take the first of equally idle servers.
func TestEjection(t *testing.T) {
	for status, ejected := range map[int]bool{http.StatusServiceUnavailable: true, http.StatusInternalServerError: false, http.StatusTooManyRequests: false} {
		urls, hits := statusBackends(t, status, http.StatusOK)
		h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: urls, FailoverSeconds: 5}}})

		for range 4 {
			send(t, h, http.MethodPost, "/", `{"model":"m"}`, "")
		}

		if got := [2]int32{hits[0].Load(), hits[1].Load()}; ejected && got != [2]int32{ejectAfter, 4} || !ejected && got != [2]int32{4, 0} {
			t.Errorf("status %d: servers got %v requests", status, got)
		}
	}
}

// An upload beyond the maximum body size says nothing about the server.
func TestOversizedUploadKeepsServer(t *testing.T) {
	urls, hits := statusBackends(t, http.StatusOK, http.StatusOK)
	h := newRouter(t, &config.Config{MaxBodyBytes: 10, Models: map[string]config.Model{"m": {URLs: urls, FailoverSeconds: 5}}})

	for range ejectAfter {
		req := httptest.NewRequest(http.MethodPost, "/llmhop/proxy/m/v1/x", strings.NewReader(strings.Repeat("a", 1<<20)))
		req.ContentLength = -1
		h.ServeHTTP(httptest.NewRecorder(), req)
	}

	if send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); hits[1].Load() != 0 {
		t.Errorf("servers got %d and %d requests", hits[0].Load(), hits[1].Load())
	}
}

// A keyed request spills from its server beyond the bound of its load.
func TestBoundedLoads(t *testing.T) {
	cfg := config.Model{URLs: []string{"http://a", "http://b"}}
	m, err := newModel("m", cfg, nil, (&Limits{}).pool("m", cfg), false)
	if err != nil {
		t.Fatal(err)
	}

	pick := func() *target {
		a := &attempt{affinity: affinity{key: hashOf("c"), keyed: true}}
		m.pick(a)

		return a.target
	}
	first := pick()

	// With six in flight on one server and none on the other, the bound
	// is ceil(1.25 * 3) + 1 = 5.
	for i := range 6 {
		if got := pick(); (got == first) != (i < 5) {
			t.Fatalf("request %d went to %s", i+2, got.up.Label)
		}
	}

	// A pinned request stays beyond the bound.
	a := &attempt{affinity: affinity{key: hashOf("c"), keyed: true, pinned: true}}
	if m.pick(a); a.target != first {
		t.Fatalf("pinned request went to %s", a.target.up.Label)
	}
}

// A server failing its probe serves only once no other one can.
func TestProbedServerSkipped(t *testing.T) {
	var hits [2]atomic.Int32
	urls := make([]string, 2)

	for i := range urls {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodGet && i == 0 {
				w.WriteHeader(http.StatusServiceUnavailable)
			}

			if r.Method == http.MethodPost {
				hits[i].Add(1)
			}
		}))
		t.Cleanup(srv.Close)
		urls[i] = srv.URL
	}

	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: urls, HealthPath: "/health"}}})
	send(t, h, http.MethodGet, "/llmhop/readiness", "", "")

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusOK || hits[0].Load() != 0 || hits[1].Load() != 1 {
		t.Fatalf("got status %d after %d and %d requests", rec.Code, hits[0].Load(), hits[1].Load())
	}
}

// A stream is aborted once it sends nothing for its idle timeout, which
// every event restarts.
func TestStreamIdleTimeout(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")

		for range 3 {
			_, _ = io.WriteString(w, "data: {}\n\n")
			_ = http.NewResponseController(w).Flush()
			time.Sleep(600 * time.Millisecond)
		}

		<-r.Context().Done()
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{backend.URL}, StreamIdleTimeoutSeconds: 1}}})

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Body.String() != strings.Repeat("data: {}\n\n", 3) {
		t.Fatalf("got %q", rec.Body)
	}
}

func TestDataParallelRanks(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{
		Affinity: config.DefaultAffinity,
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

	// A native SGLang session, routed by its path, is keyed by its body,
	// which passes verbatim.
	session := `{"session_params":{"id":"s"}}`
	send(t, h, http.MethodPost, "/llmhop/proxy/m/generate", session, "")

	if rank := captured.header.Get(rankHeader); rank != "0" && rank != "1" || captured.body != session {
		t.Fatalf("session got rank %q and body %s", rank, captured.body)
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
		Clients: map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}},
		Models:  map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.Header.Set("Authorization", "Bearer llmhop_t-secret")
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
	body := config.DefaultAffinity[1:]
	key := func(sources []config.AffinitySource, data string) affinity {
		o, err := parseObject([]byte(data))
		if err != nil {
			t.Fatal(err)
		}

		return affinityOf(req, sources, o)
	}

	if a, b := key(config.DefaultAffinity, `{"prompt_cache_key":"k"}`), key(body, `{"prompt_cache_key":"k"}`); !a.keyed || !b.keyed || a.key == b.key {
		t.Errorf("the header did not take precedence: %+v, %+v", a, b)
	}

	if a := key(body, `{"messages":[]}`); a.keyed {
		t.Errorf("keyless body got %+v", a)
	}

	if a, b := key(body, `{"session_params":{"id":"k"}}`), key(body, `{"session_params":{"id":1}}`); !a.keyed || b.keyed {
		t.Errorf("nested path got %+v and %+v", a, b)
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

// A reload keeps the servers ejected before it.
func TestEjectionSurvivesReload(t *testing.T) {
	urls, hits := statusBackends(t, http.StatusServiceUnavailable, http.StatusOK)
	limits := &Limits{}
	cfg := &config.Config{Models: map[string]config.Model{"m": {URLs: urls, FailoverSeconds: 5}}}

	for range 2 {
		rt, err := New(cfg, limits)
		if err != nil {
			t.Fatal(err)
		}

		t.Cleanup(rt.Close)

		for range ejectAfter {
			send(t, rt, http.MethodPost, "/", `{"model":"m"}`, "")
		}
	}

	if hits[0].Load() != ejectAfter {
		t.Errorf("servers got %d and %d requests", hits[0].Load(), hits[1].Load())
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

func TestTrustedSockets(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_, _ = w.Write([]byte(r.Header.Get(clientHeader)))
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Clients:     map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}, "ssh": {Listener: "ssh"}},
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
		Clients:     map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}},
		CORSOrigins: []string{"https://chat.example"},
		Models:      map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	preflight := http.Header{"Access-Control-Request-Method": {"POST"}, "Access-Control-Request-Headers": {"authorization,content-type"}}
	token := http.Header{"Authorization": {"Bearer llmhop_t-secret"}}

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
