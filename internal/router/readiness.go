package router

import (
	"context"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

// probeTimeout bounds each backend probe of GET /readiness.
const probeTimeout = 5 * time.Second

// readinessTTL is how long a probe round answers GET /readiness, so that
// frequent or concurrent callers of the unauthenticated endpoint cost at most
// one round of backend requests per interval.
const readinessTTL = time.Second

// readiness is the payload of the readiness endpoint. It reports counts only,
// since the endpoint is unauthenticated and must not reveal model names.
type readiness struct {
	Status string `json:"status"`
	Ready  int    `json:"ready"`
	Probed int    `json:"probed"`
}

// prober runs and caches probe rounds over the models with a health path.
type prober struct {
	models []*model

	mu     sync.Mutex
	at     time.Time
	status int
	body   []byte
}

// registerReadiness wires GET /readiness, which concurrently probes every
// server of every model with a health path and succeeds only if every such
// model has a server answering, so that a restarting replica leaves llmhop
// ready.
func registerReadiness(mux *http.ServeMux, models []*model) {
	p := &prober{}

	for _, m := range models {
		if m.health != "" {
			p.models = append(p.models, m)
		}
	}

	mux.HandleFunc("GET /readiness", func(w http.ResponseWriter, _ *http.Request) {
		status, body := p.result()
		writeJSON(w, status, body)
	})
}

// result returns the latest probe round, running a new one once it expired.
// Callers arriving during a round wait for it instead of starting their own.
// The round is shared by every waiting caller, so no single caller's context
// bounds it.
func (p *prober) result() (int, []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if time.Since(p.at) < readinessTTL {
		return p.status, p.body
	}

	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()

	var ready atomic.Int64
	var wg sync.WaitGroup

	for _, m := range p.models {
		wg.Go(func() {
			if m.ready(ctx) {
				ready.Add(1)
			}
		})
	}

	wg.Wait()

	body := readiness{Status: "ok", Ready: int(ready.Load()), Probed: len(p.models)}
	p.status = http.StatusOK

	if body.Ready < body.Probed {
		body.Status = "unavailable"
		p.status = http.StatusServiceUnavailable
	}

	p.at = time.Now()
	p.body = jsonBody(body)

	return p.status, p.body
}
