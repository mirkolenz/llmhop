package monitor

import "github.com/mirkolenz/llmhop/internal/telemetry"

// trendLength is how many polls a trend shows.
const trendLength = 16

// trendKey names a trend by the kind and the name of what it follows, and
// the series of llmhop whose rate it follows, empty for a share.
type trendKey struct {
	kind, name, series string
}

// The kinds of trends.
const (
	gatewayTrend = "gateway"
	hostTrend    = "host"
	gpuTrend     = "gpu"
	modelTrend   = "model"
	clientTrend  = "client"
)

// rateSeries are the series whose rates the trends of the gateway and the
// models follow, of the requests and of the generated tokens.
var rateSeries = []string{telemetry.Requests, telemetry.EngineGeneratedTokens}

// trends holds the recent values that the sparklines show.
type trends map[trendKey][]float64

// record returns the trends with the latest values of f, dropping those
// that f no longer has.
func (t trends) record(f frame) trends {
	next := make(trends)
	add := func(key trendKey, v float64) {
		trend := append(t[key], v)
		next[key] = trend[max(0, len(trend)-trendLength):]
	}

	for _, series := range rateSeries {
		add(trendKey{gatewayTrend, "", series}, f.value(series, all))

		for _, model := range f.models() {
			add(trendKey{modelTrend, model, series}, f.value(series, labeled(telemetry.Model, model)))
		}
	}

	for _, client := range f.clients() {
		add(trendKey{clientTrend, client, telemetry.Requests}, f.value(telemetry.Requests, labeled(telemetry.Client, client)))
	}

	for _, h := range f.hostRows() {
		add(trendKey{hostTrend, h.name, ""}, h.share)
	}

	for _, card := range f.now.gpus {
		add(trendKey{gpuTrend, card.ID, ""}, card.Busy)
	}

	return next
}
