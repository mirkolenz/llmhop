package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/config"
)

// An answered request counts, and only metrics listeners serve the metrics
// without a key.
func TestMetrics(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "{}")
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Listen:   map[string]config.Listener{"prometheus": {Metrics: true}},
		Policies: map[string]config.Policy{"p": {}},
		Clients:  map[string]config.Client{`a"b`: {Key: "a", PolicyName: "p"}},
		Models:   map[string]config.Model{"org/m": {URLs: []string{backend.URL}, HealthPath: "/health"}},
	})

	if rec := send(t, h, http.MethodPost, "/v1/chat/completions", `{"model":"org/m"}`, "Bearer a"); rec.Code != http.StatusOK {
		t.Fatalf("got status %d and body %q", rec.Code, rec.Body)
	}

	scrape := func(listener, path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req.WithContext(WithListener(req.Context(), listener)))

		return rec
	}

	got := scrape("prometheus", "/llmhop/metrics").Body.String()

	for _, want := range []string{
		"# TYPE llmhop_requests_total counter\n",
		`llmhop_requests_total{client="a\"b",model="org/m",code="200"} 1`,
		`llmhop_requests_in_flight{client="a\"b",model="org/m"} 0`,
		`llmhop_queue_depth{model="org/m"} 0`,
		`llmhop_backend_up{model="org/m",url="` + backend.URL + `"} 1`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %s in\n%s", want, got)
		}
	}

	if rec := scrape("default", "/llmhop/metrics"); rec.Code != http.StatusNotFound {
		t.Errorf("other listener got status %d", rec.Code)
	}
}
