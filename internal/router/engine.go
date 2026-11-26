package router

import (
	"context"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// scrapeTimeout bounds the scrape of the metrics of one server, so that a
// hanging one delays a request of the metrics of llmhop by that much at
// most.
const scrapeTimeout = 2 * time.Second

// scrapeMaxAge is how long the scrape of a server answers every request of
// the metrics, so that any number of viewers and scrapers costs an engine
// one scrape per that long at most.
const scrapeMaxAge = time.Second

// maxScrapeBytes bounds the metrics of a server.
const maxScrapeBytes = 16 << 20

// scraped is the latest engine series of a server, nil if it failed to
// report them.
type scraped struct {
	mu     sync.Mutex
	at     time.Time
	values map[string]float64
}

// engine returns the engine series of t, scraping them unless the latest
// scrape is recent, or nil if the server fails to report them. Concurrent
// requests wait for one scrape.
func (m *model) engine(ctx context.Context, t *target) map[string]float64 {
	t.scraped.mu.Lock()
	defer t.scraped.mu.Unlock()

	if time.Since(t.scraped.at) >= scrapeMaxAge {
		// The scrape answers every request of the next second, so it outlives
		// a request that leaves.
		t.scraped.values, t.scraped.at = m.scrape(context.WithoutCancel(ctx), t), time.Now()
	}

	return t.scraped.values
}

// scrape returns the engine series of t, or nil if it fails to report them.
func (m *model) scrape(ctx context.Context, t *target) map[string]float64 {
	ctx, cancel := context.WithTimeout(ctx, scrapeTimeout)
	defer cancel()

	req, err := m.get(ctx, m.metricsPath, t)
	if err != nil {
		return nil
	}

	var values map[string]float64

	err = t.up.Fetch(req, func(body io.Reader) (err error) {
		// Metrics beyond the bound fail the scrape rather than end it early.
		values, err = telemetry.Engine(http.MaxBytesReader(nil, io.NopCloser(body), maxScrapeBytes))

		return err
	})
	if err != nil {
		return nil
	}

	return values
}
