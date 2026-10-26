package router

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
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

// prober runs and caches probe rounds over the backends with a health path.
type prober struct {
	backends map[string]*backend

	mu     sync.Mutex
	at     time.Time
	status int
	body   []byte
}

// registerReadiness wires GET /readiness, which concurrently probes the health
// path of every backend that configures one and succeeds only if all answer.
func registerReadiness(mux *http.ServeMux, backends map[string]*backend) {
	p := &prober{backends: make(map[string]*backend)}
	for name, b := range backends {
		if b.health != "" {
			p.backends[name] = b
		}
	}

	mux.HandleFunc("GET /readiness", func(w http.ResponseWriter, _ *http.Request) {
		status, body := p.result()
		writeJSON(w, status, body)
	})
}

// result returns the latest probe round, running a new one once it expired.
// Callers arriving during a round wait for it instead of starting their own.
func (p *prober) result() (int, []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if time.Since(p.at) < readinessTTL {
		return p.status, p.body
	}

	var ready atomic.Int64
	var wg sync.WaitGroup

	for name, b := range p.backends {
		wg.Go(func() {
			if err := b.probe(); err != nil {
				log.Printf("readiness: models.%s: %v", name, err)
				return
			}

			ready.Add(1)
		})
	}

	wg.Wait()

	body := readiness{Status: "ok", Ready: int(ready.Load()), Probed: len(p.backends)}
	p.status = http.StatusOK

	if body.Ready < body.Probed {
		body.Status = "unavailable"
		p.status = http.StatusServiceUnavailable
	}

	p.at = time.Now()
	p.body = jsonBody(body)

	return p.status, p.body
}

// probe sends GET to the health path of the backend and fails unless it
// answers with a 2xx. Redirects are not followed. The round is shared by
// every waiting caller, so no single caller's context bounds it.
func (b *backend) probe() error {
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, b.health, nil)
	if err != nil {
		return err
	}

	// A probe has no client request, so it stands in for its own, whose empty
	// Host lets the backend URL host apply unless one is configured.
	b.rewrite(&httputil.ProxyRequest{In: req, Out: req})

	resp, err := b.up.Transport.RoundTrip(req)
	if err != nil {
		return err
	}

	// Draining lets the transport reuse the connection for the next round.
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4<<10))
	_ = resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}

	return nil
}
