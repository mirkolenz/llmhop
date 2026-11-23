package router

import (
	"maps"
	"net/http"
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
	status        int
}

// request counts an answered request.
func (m *metrics) request(e *entry, status int) {
	client, _ := e.names()

	m.mu.Lock()
	defer m.mu.Unlock()

	ensure(&m.requests)[requestKey{client, e.served, status}]++
}

// counts returns a copy of the request counts.
func (m *metrics) counts() map[requestKey]int {
	m.mu.Lock()
	defer m.mu.Unlock()

	return maps.Clone(m.requests)
}

// Metrics is the state of llmhop that GET /llmhop/metrics serves as JSON.
type Metrics struct {
	// Requests counts the answered requests since llmhop started.
	Requests []Requests `json:"requests"`
	// Models holds the present state of each model.
	Models []ModelMetrics `json:"models"`
}

// Requests is the number of answered requests of a client to a model with
// a status, where a request that reached no model has none.
type Requests struct {
	Client string `json:"client"`
	Model  string `json:"model"`
	Status int    `json:"status"`
	Count  int    `json:"count"`
}

// ModelMetrics is the present state of a model.
type ModelMetrics struct {
	Name string `json:"name"`
	// Queued is the number of requests waiting for their slots.
	Queued int `json:"queued"`
	// Running is the number of requests holding their slots by client.
	Running map[string]int `json:"running"`
	// Up tells by URL whether each server answered its latest probe,
	// absent without a health path.
	Up map[string]bool `json:"up,omitempty"`
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

// metricsHandler serves the metrics of a router.
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
	m := Metrics{Requests: []Requests{}, Models: make([]ModelMetrics, len(x.models))}

	for k, n := range x.limits.metrics.counts() {
		m.Requests = append(m.Requests, Requests{k.client, k.model, k.status, n})
	}

	for i, md := range x.models {
		m.Models[i] = ModelMetrics{Name: md.name, Queued: occupancy[i].waiting, Running: occupancy[i].running}

		if md.health == "" {
			continue
		}

		m.Models[i].Up = make(map[string]bool, len(md.servers))

		for _, t := range md.servers {
			m.Models[i].Up[t.up.Label] = md.healthy(t.server)
		}
	}

	writeJSON(w, http.StatusOK, jsonBody(m))
}
