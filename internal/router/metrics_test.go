package router

import (
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// engineMetrics are those of two vLLM ranks, with a label value holding
// an escaped quote and a brace, and a timestamp.
const engineMetrics = `# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total{engine="0",model_name="m"} 3
vllm:generation_tokens_total{engine="1",model_name="a \"}"} 4 1700000000
vllm:kv_cache_usage_perc{engine="0"} 0.25
vllm:kv_cache_usage_perc{engine="1"} 0.5
`

// An answered request counts, and only metrics listeners serve the metrics
// without a key.
func TestMetrics(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/metrics" {
			_, _ = io.WriteString(w, engineMetrics)

			return
		}

		_, _ = io.WriteString(w, "{}")
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Listen:   map[string]config.Listener{"monitor": {Metrics: true}},
		Policies: map[string]config.Policy{"p": {MaxConcurrentRequests: new(uint32(3)), RequestsPerMinute: new(uint32(60))}},
		Clients:  map[string]config.Client{"a": {KeyHash: apikey.Of("llmhop_a-secret"), PolicyName: "p"}},
		Models:   map[string]config.Model{"org/m": {URLs: []string{backend.URL}, HealthPath: "/health", MetricsPath: "/metrics", MaxConcurrentRequests: 4}},
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

	rec := scrape("monitor")

	if rec.Code != http.StatusOK {
		t.Fatalf("got status %d", rec.Code)
	}

	samples, err := telemetry.Parse(rec.Body)
	if err != nil {
		t.Fatal(err)
	}

	// Each series by its name and labels, rendered as llmhop renders them.
	got := make(map[string]float64)

	for _, s := range samples {
		var kv []string

		for _, k := range slices.Sorted(maps.Keys(s.Labels)) {
			kv = append(kv, k, s.Labels[k])
		}

		got[s.Name+telemetry.Labels(kv...)] = s.Value
	}

	server := telemetry.Labels("model", "org/m", "server", backend.URL)
	want := map[string]float64{
		`llmhop_requests_total{client="a",model="org/m",status="200"}`: 1,
		`llmhop_request_duration_seconds_count{model="org/m"}`:         1,
		`llmhop_queued_requests{model="org/m"}`:                        0,
		`llmhop_running_requests{client="a",model="org/m"}`:            0,
		"llmhop_server_up" + server:                                    1,
		"llmhop_engine_generation_tokens_total" + server:               7,
		"llmhop_engine_kv_cache_usage_ratio" + server:                  0.5,
		"llmhop_engine_up" + server:                                    1,
		`llmhop_max_running_requests{model="org/m"}`:                   4,
		`llmhop_client_max_running_requests{client="a"}`:               3,
		`llmhop_client_max_requests_per_minute{client="a"}`:            60,
		`llmhop_client_remaining_requests{client="a"}`:                 59,
	}

	for series, v := range want {
		if g, ok := got[series]; !ok || g != v {
			t.Errorf("%s: got %v (present %v), want %v", series, g, ok, v)
		}
	}

	if got[`llmhop_request_duration_seconds_sum{model="org/m"}`] <= 0 {
		t.Error("the request took no time")
	}

	if rec := scrape("default"); rec.Code != http.StatusNotFound {
		t.Errorf("other listener got status %d", rec.Code)
	}
}
