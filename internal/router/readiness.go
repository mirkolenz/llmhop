package router

import (
	"context"
	"log/slog"
	"net/http"
	"slices"
	"sync"
	"time"
)

// probeTimeout bounds each probe of a server.
const probeTimeout = 5 * time.Second

// probeInterval is how often each server is probed, so that frequent
// callers of the unauthenticated endpoints cost no backend requests.
const probeInterval = time.Second

// readiness is the payload of the readiness endpoint. It reports counts only,
// since the endpoint is unauthenticated and must not reveal model names.
type readiness struct {
	Status string `json:"status"`
	Ready  int    `json:"ready"`
	Probed int    `json:"probed"`
}

// prober probes each server of the models with a health path on its own in
// the background once started, recording every result for routing,
// readiness and the metrics, until stopped.
type prober struct {
	models []*model
	// ready is closed once every server reported a probe, here or in the
	// router a reload replaced.
	ready chan struct{}
	// cancel stops it once started.
	cancel context.CancelFunc
}

func newProber(models []*model) *prober {
	p := &prober{ready: make(chan struct{})}

	for _, m := range models {
		if m.health != "" {
			p.models = append(p.models, m)
		}
	}

	return p
}

// start probes in the background until stopped, called at most once.
func (p *prober) start() {
	ctx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel

	var first sync.WaitGroup

	for _, m := range p.models {
		for _, t := range m.servers {
			if m.unprobed(t.server) {
				first.Add(1)
				go p.watch(ctx, m, t, sync.OnceFunc(first.Done))
			} else {
				go p.watch(ctx, m, t, func() {})
			}
		}
	}

	go func() {
		first.Wait()
		close(p.ready)
	}()
}

// stop ends the probes, if started.
func (p *prober) stop() {
	if p.cancel != nil {
		p.cancel()
	}
}

// wait waits until every server reported a probe or ctx is done, and
// reports whether they did.
func (p *prober) wait(ctx context.Context) bool {
	select {
	case <-p.ready:
		return true
	case <-ctx.Done():
		return false
	}
}

// watch probes t every interval until ctx is done, calling reported after
// each result and once done, so that stopping before a first result leaves
// no waiter blocked.
func (p *prober) watch(ctx context.Context, m *model, t *target, reported func()) {
	ticker := time.NewTicker(probeInterval)
	defer ticker.Stop()
	defer reported()

	for {
		timeout, cancel := context.WithTimeout(ctx, probeTimeout)
		err := m.probe(timeout, t)
		cancel()

		// A stopped prober's results no longer matter.
		if ctx.Err() != nil {
			return
		}

		if err != nil {
			slog.Warn("probe", "model", m.name, "server", t.up.Label, "err", err)
		}

		m.probed(t.server, err)
		reported()

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// registerReadiness wires GET /llmhop/readiness, which succeeds only if
// every model with a health path has a server answering, so that a
// restarting replica leaves llmhop ready.
func registerReadiness(mux *http.ServeMux, p *prober) {
	mux.HandleFunc("GET "+reservedPrefix+"readiness", func(w http.ResponseWriter, req *http.Request) {
		if !p.wait(req.Context()) {
			return
		}

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
