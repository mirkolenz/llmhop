package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/mirkolenz/llmhop/internal/config"
)

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
