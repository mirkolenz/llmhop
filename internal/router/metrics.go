package router

import (
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/VictoriaMetrics/metrics"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// The metrics of llmhop carry their types for Prometheus.
func init() {
	metrics.ExposeMetadata(true)
}

// durationBuckets bound the buckets of the request durations, from 50 ms
// to about 7 minutes.
var durationBuckets = metrics.ExponentialBuckets(0.05, 2, 14)

// stats counts the answered requests and their durations, in Limits so
// that a reload keeps them. The zero value is ready to use.
type stats struct {
	once sync.Once
	set  *metrics.Set
}

// series returns the series of the requests.
func (s *stats) series() *metrics.Set {
	s.once.Do(func() { s.set = metrics.NewSet() })

	return s.set
}

// response is how a request was answered.
type response struct {
	status int
	// completed tells whether it was sent in full, and stream whether it is
	// an event stream, whose first byte is its first token.
	completed, stream bool
	// duration is how long it took and firstByte until the first byte of
	// its body, zero without any.
	duration, firstByte time.Duration
}

// request counts a request answered by r.
func (s *stats) request(e *entry, r response) {
	client, _ := e.names()
	set := s.series()
	set.GetOrCreateCounter(telemetry.Requests + telemetry.Labels(telemetry.Client, client, telemetry.Model, e.served, telemetry.Status, strconv.Itoa(r.status))).Inc()

	// Only the successful requests of a model sent in full tell how long it
	// takes.
	if e.served == "" || r.status >= 400 || !r.completed {
		return
	}

	model := telemetry.Labels(telemetry.Model, e.served)
	set.GetOrCreatePrometheusHistogramExt(telemetry.RequestDuration+model, durationBuckets).Update(r.duration.Seconds())

	if r.stream && r.firstByte > 0 {
		set.GetOrCreatePrometheusHistogramExt(telemetry.RequestFirstToken+model, durationBuckets).Update(r.firstByte.Seconds())
	}
}

// metricsOnly serves next on the listeners with metrics only.
func metricsOnly(listen map[string]config.Listener, next http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if !listen[listenerOf(req)].Metrics {
			notFound(w, req)

			return
		}

		next.ServeHTTP(w, req)
	}
}

// metricsHandler serves the metrics of a router in the Prometheus text
// format: the counted requests, the present state of each model and its
// servers, what the engines of the servers with a metrics path report, and
// those of the process.
type metricsHandler struct {
	limits *Limits
	models []*model
	prober *prober
}

func (x *metricsHandler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if !x.prober.wait(req.Context()) {
		return
	}

	occupancy := x.limits.occupancy(x.models)
	state := metrics.NewSet()
	gauge := func(name string, v float64) { state.GetOrCreateGauge(name, nil).Set(v) }

	// The servers report their engines concurrently, each within the
	// scrape timeout.
	var scrapes sync.WaitGroup

	for client, c := range x.limits.clientLimits() {
		labels := telemetry.Labels(telemetry.Client, client)

		if c.slots > 0 {
			gauge(telemetry.ClientMaxRunningRequests+labels, float64(c.slots))
		}

		if c.requests.limited {
			gauge(telemetry.ClientMaxRequestsPerMinute+labels, c.requests.size)
			gauge(telemetry.ClientRemainingRequests+labels, math.Floor(max(0, c.requests.remaining)))
		}
	}

	for i, md := range x.models {
		model := telemetry.Labels(telemetry.Model, md.name)
		gauge(telemetry.QueuedRequests+model, float64(occupancy[i].waiting))

		if occupancy[i].slots > 0 {
			gauge(telemetry.MaxRunningRequests+model, float64(occupancy[i].slots))
		}

		for client, n := range occupancy[i].running {
			gauge(telemetry.RunningRequests+telemetry.Labels(telemetry.Model, md.name, telemetry.Client, client), float64(n))
		}

		for _, t := range md.servers {
			server := telemetry.Labels(telemetry.Model, md.name, telemetry.Server, t.up.Label)

			if md.health != "" {
				gauge(telemetry.ServerUp+server, one(md.healthy(t.server)))
			}

			if md.metricsPath != "" {
				scrapes.Go(func() {
					values := md.engine(req.Context(), t)

					for name, v := range values {
						if telemetry.Counter(name) {
							state.GetOrCreateFloatCounter(name + server).Set(v)
						} else {
							gauge(name+server, v)
						}
					}

					gauge(telemetry.EngineUp+server, one(values != nil))
				})
			}
		}
	}

	scrapes.Wait()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	x.limits.stats.series().WritePrometheus(w)
	state.WritePrometheus(w)
	metrics.WriteProcessMetrics(w)
}

// one is 1 if b holds, else 0.
func one(b bool) float64 {
	if b {
		return 1
	}

	return 0
}
