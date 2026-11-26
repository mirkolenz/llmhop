package router

import (
	"encoding/json/v2"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
)

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
