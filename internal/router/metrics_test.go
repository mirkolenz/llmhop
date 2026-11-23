package router

import (
	"encoding/json/v2"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/mirkolenz/llmhop/internal/apikey"
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
		Listen:   map[string]config.Listener{"monitor": {Metrics: true}},
		Policies: map[string]config.Policy{"p": {}},
		Clients:  map[string]config.Client{"a": {KeyHash: apikey.Of("llmhop_a-secret"), PolicyName: "p"}},
		Models:   map[string]config.Model{"org/m": {URLs: []string{backend.URL}, HealthPath: "/health"}},
	})

	if rec := send(t, h, http.MethodPost, "/v1/chat/completions", `{"model":"org/m"}`, "Bearer llmhop_a-secret"); rec.Code != http.StatusOK {
		t.Fatalf("got status %d and body %q", rec.Code, rec.Body)
	}

	scrape := func(listener string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/llmhop/metrics", nil)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req.WithContext(WithListener(req.Context(), listener)))

		return rec
	}

	var got Metrics

	if err := json.Unmarshal(scrape("monitor").Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}

	want := Metrics{
		Requests: []Requests{{Client: "a", Model: "org/m", Status: http.StatusOK, Count: 1}},
		Models:   []ModelMetrics{{Name: "org/m", Running: map[string]int{"a": 0}, Up: map[string]bool{backend.URL: true}}},
	}

	if g, w := jsonBody(got), jsonBody(want); string(g) != string(w) {
		t.Errorf("got %s, want %s", g, w)
	}

	if rec := scrape("default"); rec.Code != http.StatusNotFound {
		t.Errorf("other listener got status %d", rec.Code)
	}
}
