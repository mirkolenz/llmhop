package router

import (
	"fmt"
	"maps"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"github.com/mirkolenz/llmhop/internal/config"
)

// metrics counts the answered requests, in Limits so that a reload keeps
// them. The zero value is ready to use.
type metrics struct {
	mu       sync.Mutex
	requests map[requestKey]int
}

// requestKey is what the requests are counted by.
type requestKey struct {
	client, model string
	code          int
}

// request counts an answered request.
func (m *metrics) request(e *entry, code int) {
	client, _ := e.names()

	m.mu.Lock()
	defer m.mu.Unlock()

	ensure(&m.requests)[requestKey{client, e.served, code}]++
}

// counts returns a copy of the request counts.
func (m *metrics) counts() map[requestKey]int {
	m.mu.Lock()
	defer m.mu.Unlock()

	return maps.Clone(m.requests)
}

// labelEscaper escapes a label value as in the text format.
var labelEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)

// exposition builds the text format family by family.
type exposition struct {
	b    []byte
	name string
}

// family starts the family called name.
func (x *exposition) family(name, kind, help string) {
	x.name = name
	x.b = fmt.Appendf(x.b, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind)
}

// sample appends a sample of the current family with pairs of label names
// and values.
func (x *exposition) sample(v int, pairs ...string) {
	x.b = append(append(x.b, x.name...), '{')

	for i := 0; i < len(pairs); i += 2 {
		if i > 0 {
			x.b = append(x.b, ',')
		}

		x.b = fmt.Appendf(x.b, `%s="%s"`, pairs[i], labelEscaper.Replace(pairs[i+1]))
	}

	x.b = fmt.Appendf(x.b, "} %d\n", v)
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

// exporter serves the metrics of a router.
type exporter struct {
	limits *Limits
	models []*model
	prober *prober
}

func (x *exporter) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	occupancy := x.limits.occupancy(x.models)
	var e exposition

	e.family("llmhop_requests_total", "counter", "Requests answered by llmhop.")

	for k, n := range x.limits.metrics.counts() {
		e.sample(n, "client", k.client, "model", k.model, "code", strconv.Itoa(k.code))
	}

	e.family("llmhop_requests_in_flight", "gauge", "Requests holding their slots.")

	for i, m := range x.models {
		for client, n := range occupancy[i].running {
			e.sample(n, "client", client, "model", m.name)
		}
	}

	e.family("llmhop_queue_depth", "gauge", "Requests waiting for their slots.")

	for i, m := range x.models {
		e.sample(occupancy[i].waiting, "model", m.name)
	}

	e.family("llmhop_backend_up", "gauge", "Whether a server of a model answers on its health path.")

	<-x.prober.ready

	for _, m := range x.prober.models {
		for _, t := range m.servers {
			var up int
			if m.healthy(t.server) {
				up = 1
			}

			e.sample(up, "model", m.name, "url", t.up.Label)
		}
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write(e.b)
}
