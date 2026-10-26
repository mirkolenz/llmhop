package router

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/iotest"

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
	h, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}

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

func TestCheckBearer(t *testing.T) {
	tokens := [][]byte{[]byte("alpha"), []byte("beta")}
	cases := []struct {
		header string
		want   bool
	}{
		{"Bearer beta", true},
		{"bearer alpha", true},
		{"Bearer alph", false},
		{"Basic alpha", false},
		{"alpha", false},
	}

	for _, c := range cases {
		if got := checkBearer(c.header, tokens); got != c.want {
			t.Errorf("checkBearer(%q) = %v, want %v", c.header, got, c.want)
		}
	}
}

func TestCatalog(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{AuthTokens: []string{"secret"}, Models: map[string]config.Model{
		"b":        {URL: backend.URL},
		"a":        {URL: backend.URL},
		"detector": {URL: backend.URL, Unlisted: true},
	}})

	t.Run("health needs no token and counts listed models", func(t *testing.T) {
		var got health
		if err := json.Unmarshal(send(t, h, http.MethodGet, "/health", "", "").Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if got.Status != "ok" || got.Models != 2 {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("list is sorted and omits unlisted models", func(t *testing.T) {
		var got modelList
		if err := json.Unmarshal(send(t, h, http.MethodGet, "/v1/models", "", "Bearer secret").Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if len(got.Data) != 2 || got.Data[0].ID != "a" || got.Data[1].ID != "b" {
			t.Fatalf("got models %+v", got.Data)
		}
	})

	t.Run("retrieve", func(t *testing.T) {
		if rec := send(t, h, http.MethodGet, "/v1/models/a", "", "Bearer secret"); rec.Code != http.StatusOK {
			t.Fatalf("got status %d", rec.Code)
		}

		if rec := send(t, h, http.MethodGet, "/v1/models/detector", "", "Bearer secret"); rec.Code != http.StatusNotFound {
			t.Fatalf("got status %d", rec.Code)
		}
	})

	t.Run("requires a token", func(t *testing.T) {
		if rec := send(t, h, http.MethodGet, "/v1/models", "", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("got status %d", rec.Code)
		}
	})
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
		checkFwd   func(t *testing.T, req *capturedRequest)
	}{
		{name: "invalid JSON", body: `{"model":`, wantCode: http.StatusBadRequest},
		{name: "missing model", body: `{}`, wantCode: http.StatusBadRequest},
		{name: "null model", body: `{"model":null}`, wantCode: http.StatusBadRequest},
		{name: "non-string model", body: `{"model":123}`, wantCode: http.StatusBadRequest},
		{name: "duplicate model key", body: `{"model":"m","model":null}`, wantCode: http.StatusBadRequest},
		{name: "unknown model", body: `{"model": "nope"}`, wantCode: http.StatusNotFound},
		{name: "auth runs before model lookup", auth: []string{"secret"}, body: `{"model": "unknown"}`, wantCode: http.StatusUnauthorized},
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
				AuthTokens:   c.auth,
				MaxBodyBytes: c.maxBody,
				Models:       map[string]config.Model{"m": {URL: backend.URL, Headers: c.headers}},
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
		"m": {URL: backend.URL + "/base?backend=1"},
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
	h := newRouter(t, &config.Config{AuthTokens: []string{"secret"}, Models: map[string]config.Model{
		"detector": {URL: backend.URL + "/base", Unlisted: true},
	}})

	if rec := send(t, h, http.MethodPost, "/route/detector/detect?x=1", `{"text":"candidate"}`, "Bearer secret"); rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	if captured.path != "/base/detect" || captured.query != "x=1" || captured.body != `{"text":"candidate"}` {
		t.Fatalf("backend saw %+v", captured)
	}

	if rec := send(t, h, http.MethodPost, "/route/nope/detect", "", "Bearer secret"); rec.Code != http.StatusNotFound {
		t.Fatalf("got status %d", rec.Code)
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
			proxyHandler(nil, c.maxBytes, nil)(rec, req)

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
		"a": {URL: slow.URL, MaxConcurrentRequests: 1},
		"b": {URL: fast.URL, MaxConcurrentRequests: 1},
	}})

	done := make(chan struct{})

	go func() {
		send(t, h, http.MethodPost, "/", `{"model":"a"}`, "")
		close(done)
	}()

	// Returns once the first request holds the only slot of model a.
	<-entered

	if rec := send(t, h, http.MethodPost, "/", `{"model":"a"}`, ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("saturated model got status %d, want 503", rec.Code)
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
		"tcp":      {URL: tcp.URL, Health: "/health", Headers: map[string]string{"X-Key": "k", "Host": "probe.example"}},
		"unix":     {URL: "unix://" + socket, Health: "/health", Headers: map[string]string{"X-Key": "k"}},
		"unprobed": {URL: tcp.URL},
	}

	check := func(wantCode int, want readiness) {
		t.Helper()
		h := newRouter(t, &config.Config{AuthTokens: []string{"secret"}, Models: models})
		rec := send(t, h, http.MethodGet, "/readiness", "", "")

		var got readiness
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}

		if rec.Code != wantCode || got != want {
			t.Errorf("got status %d and %+v, want %d and %+v", rec.Code, got, wantCode, want)
		}
	}

	check(http.StatusOK, readiness{Status: "ok", Ready: 2, Probed: 2})
	models["broken"] = config.Model{URL: tcp.URL, Health: "/missing"}
	check(http.StatusServiceUnavailable, readiness{Status: "unavailable", Ready: 2, Probed: 3})
}

func TestBufferedRequestLimit(t *testing.T) {
	srv, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedRequests: 1,
		Models:              map[string]config.Model{"m": {URL: srv.URL}},
	})

	// The first body arrives slowly, so its request holds the only slot.
	body, writer := io.Pipe()
	done := make(chan struct{})

	go func() {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", body))
		close(done)
	}()

	if _, err := writer.Write([]byte(`{"model":`)); err != nil {
		t.Fatal(err)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("buffered request got status %d, want 503", rec.Code)
	}

	// Path-routed bodies stream, so they need no slot.
	if rec := send(t, h, http.MethodPost, "/route/m/", "{}", ""); rec.Code != http.StatusOK {
		t.Errorf("streamed request got status %d, want 200", rec.Code)
	}

	_ = writer.CloseWithError(io.ErrUnexpectedEOF)
	<-done

	// Forwarding the body released its slot.
	for range 2 {
		if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusOK {
			t.Errorf("buffered request got status %d, want 200", rec.Code)
		}
	}
}

func TestBufferedSlotReleasedOnceSent(t *testing.T) {
	entered, unblock := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		entered <- struct{}{}
		<-unblock
	}))
	t.Cleanup(slow.Close)
	fast, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedRequests: 1,
		Models:              map[string]config.Model{"slow": {URL: slow.URL}, "fast": {URL: fast.URL}},
	})

	done := make(chan struct{})

	go func() {
		send(t, h, http.MethodPost, "/", `{"model":"slow"}`, "")
		close(done)
	}()

	<-entered

	// The slow response still runs, but its body was sent.
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
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URL: srv.URL}}})

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
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URL: srv.URL}}})

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
