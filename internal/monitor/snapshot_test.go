package monitor

import (
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// Rates sum the increase of each series between two snapshots, by the
// labels they match. A new counter of llmhop counts from zero, while one of
// an engine missing a scrape neither hides nor inflates the rest.
func TestFrame(t *testing.T) {
	snap := func(text string) *snapshot {
		samples, err := telemetry.Parse(strings.NewReader(text))
		if err != nil {
			t.Fatal(err)
		}

		return &snapshot{samples: samples}
	}

	last := snap(`llmhop_requests_total{model="m",status="200"} 10
llmhop_request_duration_seconds_sum{model="m"} 5
llmhop_request_duration_seconds_count{model="m"} 10
llmhop_engine_generation_tokens_total{model="m",server="a"} 100
llmhop_engine_generation_tokens_total{model="m",server="b"} 50
`)
	now := snap(`llmhop_requests_total{model="m",status="200"} 14
llmhop_requests_total{model="m",status="429"} 2
llmhop_request_duration_seconds_sum{model="m"} 9
llmhop_request_duration_seconds_count{model="m"} 12
llmhop_engine_generation_tokens_total{model="m",server="a"} 120
`)
	back := snap(`llmhop_engine_generation_tokens_total{model="m",server="a"} 140
llmhop_engine_generation_tokens_total{model="m",server="b"} 60
`)
	f := frame{last, now, 2}
	m := labeled("model", "m")

	for name, c := range map[string]struct{ got, want float64 }{
		"requests":   {f.rate("llmhop_requests_total", m), 3},
		"rejections": {f.rate("llmhop_requests_total", both(m, status(429, 429))), 1},
		"latency":    {f.mean("llmhop_request_duration_seconds", m), 2},
		"vanished":   {f.rate("llmhop_engine_generation_tokens_total", m), 10},
		"returned":   {frame{now, back, 2}.rate("llmhop_engine_generation_tokens_total", m), 10},
		"restart":    {frame{now, last, 2}.rate("llmhop_requests_total", m), 5},
	} {
		if c.got != c.want {
			t.Errorf("%s: got %v, want %v", name, c.got, c.want)
		}
	}
}
