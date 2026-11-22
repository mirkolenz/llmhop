package router

import (
	"context"
	"log/slog"
	"net/http"
	"slices"
	"sync"
	"time"
)

// probeTimeout bounds each probe round of the backends.
const probeTimeout = 5 * time.Second

// probeInterval is how often the servers are probed, so that frequent
// callers of the unauthenticated endpoints cost no backend requests.
const probeInterval = time.Second

// readiness is the payload of the readiness endpoint. It reports counts only,
// since the endpoint is unauthenticated and must not reveal model names.
type readiness struct {
	Status string `json:"status"`
	Ready  int    `json:"ready"`
	Probed int    `json:"probed"`
}

// prober probes the servers of the models with a health path in the
// background, recording the result of each server for routing, readiness
// and the metrics, until stopped.
type prober struct {
	models []*model
	// ready is closed once the first round finished.
	ready chan struct{}
	stop  context.CancelFunc
}

func startProber(models []*model) *prober {
	ctx, stop := context.WithCancel(context.Background())
	p := &prober{ready: make(chan struct{}), stop: stop}

	for _, m := range models {
		if m.health != "" {
			p.models = append(p.models, m)
		}
	}

	if len(p.models) == 0 {
		close(p.ready)

		return p
	}

	go p.run(ctx)

	return p
}

// run probes every interval until ctx is done.
func (p *prober) run(ctx context.Context) {
	p.round(ctx)
	close(p.ready)

	ticker := time.NewTicker(probeInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.round(ctx)
		}
	}
}

// round probes every server once.
func (p *prober) round(ctx context.Context) {
	timeout, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()

	var wg sync.WaitGroup

	for _, m := range p.models {
		for _, t := range m.servers {
			wg.Go(func() {
				err := m.probe(timeout, t)

				// A stopped prober's results no longer matter.
				if ctx.Err() != nil {
					return
				}

				if err != nil {
					slog.Warn("probe", "model", m.name, "server", t.up.Label, "err", err)
				}

				m.probed(t.server, err)
			})
		}
	}

	wg.Wait()
}

// registerReadiness wires GET /llmhop/readiness, which succeeds only if
// every model with a health path has a server answering, so that a
// restarting replica leaves llmhop ready.
func registerReadiness(mux *http.ServeMux, p *prober) {
	mux.HandleFunc("GET "+reservedPrefix+"readiness", func(w http.ResponseWriter, _ *http.Request) {
		<-p.ready
		body := readiness{Status: "ok", Probed: len(p.models)}
		status := http.StatusOK

		for _, m := range p.models {
			if slices.ContainsFunc(m.servers, func(t *target) bool { return m.healthy(t.server) }) {
				body.Ready++
			}
		}

		if body.Ready < body.Probed {
			body.Status = "unavailable"
			status = http.StatusServiceUnavailable
		}

		writeJSON(w, status, jsonBody(body))
	})
}
