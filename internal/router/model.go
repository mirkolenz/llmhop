package router

import (
	"cmp"
	"context"
	"maps"
	"net/http"
	"net/http/httputil"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// rankHeader pins a request to one data-parallel rank of a vLLM or SGLang
// server.
const rankHeader = "X-Data-Parallel-Rank"

// model is a configured model with the servers serving it. Their in-flight
// counts and health only exist to spread the requests of this process, so
// every instance of llmhop decides alone, while a reload keeps them.
type model struct {
	name    string
	headers http.Header
	// host overrides the outgoing Host when set, since Go carries Host
	// outside the header map.
	host   string
	health string
	// servers are the targets of keyless requests, one per URL without a rank.
	servers []*target
	// targets are the targets of requests with an affinity key, the ranks of
	// every server if it has several, else the servers.
	targets []*target
	// queue admits the proxied requests over all servers.
	queue        *queue
	queueTimeout time.Duration
	failover     time.Duration
	streamIdle   time.Duration
	proxy        *httputil.ReverseProxy

	// mu guards the in-flight counts and health of every server, that of
	// its pool.
	mu *sync.Mutex
}

// server is the state of one URL of a model, which its pool keeps across
// reloads that keep its health path.
type server struct {
	inflight int
	// failures counts the requests it failed in a row.
	failures int
	// avoidUntil is when a server avoided after failed requests serves
	// again.
	avoidUntil time.Time
	// probed is whether a probe reported, and probeFailed avoids a server
	// until a probe passes.
	probed, probeFailed bool
}

// avoided reports whether s serves only once no other server can.
func (s *server) avoided(now time.Time) bool {
	return s.probeFailed || now.Before(s.avoidUntil)
}

// target is a server or one of its data-parallel ranks.
type target struct {
	*server
	up   *upstream.Upstream
	rank string
	// id seeds the rendezvous hash, the same in every llmhop instance.
	id uint64
}

// newModel builds the model of m. With stripCORS, llmhop alone decides which
// pages may read a response, as it does whenever tokens are required.
func newModel(name string, m config.Model, q *queue, p *pool, stripCORS bool) (*model, error) {
	headers := make(http.Header, len(m.Headers))

	for k, v := range m.Headers {
		headers.Set(k, v)
	}

	md := &model{
		name:         name,
		headers:      headers,
		host:         headers.Get("Host"),
		health:       m.HealthPath,
		queue:        q,
		mu:           &p.mu,
		queueTimeout: time.Duration(m.QueueTimeoutSeconds) * time.Second,
		failover:     time.Duration(m.FailoverSeconds) * time.Second,
		streamIdle:   time.Duration(m.StreamIdleTimeoutSeconds) * time.Second,
	}
	headers.Del("Host")

	for i, raw := range m.URLs {
		up, err := upstream.Parse(raw, time.Duration(m.ResponseTimeoutSeconds)*time.Second)
		if err != nil {
			return nil, err
		}

		// The position tells apart the URLs that differ only in their query,
		// which a label leaves out.
		if slices.ContainsFunc(md.servers, func(t *target) bool { return t.up.Label == up.Label }) {
			up.Label += "#" + strconv.Itoa(i)
		}

		s := p.servers[serverKey{raw, m.HealthPath}]
		whole := &target{server: s, up: up, id: hashOf(raw)}
		md.servers = append(md.servers, whole)

		// Unset is zero, a single rank like one.
		if m.DataParallelSize < 2 {
			md.targets = append(md.targets, whole)
			continue
		}

		for rank := range m.DataParallelSize {
			r := strconv.FormatUint(uint64(rank), 10)
			md.targets = append(md.targets, &target{server: s, up: up, rank: r, id: hashOf(raw, r)})
		}
	}

	md.proxy = &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			// ReverseProxy drops unparsable queries, forward them verbatim instead.
			r.Out.URL.RawQuery = r.In.URL.RawQuery
			r.SetXForwarded()

			// Only llmhop names the client and picks ranks, never the client itself.
			r.Out.Header.Del(clientHeader)
			r.Out.Header.Del(rankHeader)

			// ReverseProxy clears the headers set before the proxy, such as the
			// rate limits, on a 1xx, while llmhop reads or streams the body
			// anyway.
			r.Out.Header.Del("Expect")

			if c := entryOf(r.In).client; c != nil && c.name != "" {
				r.Out.Header.Set(clientHeader, c.name)
			}

			a := attemptOf(r.In)
			a.path = *r.Out.URL
			md.address(r.Out, a.path, a.target)
		},
		Transport: md,
		ModifyResponse: func(resp *http.Response) error {
			// llmhop already answers with the ID, which a backend may echo.
			resp.Header.Del(requestIDHeader)

			// The default CORS headers of a backend such as vLLM never apply.
			if stripCORS {
				maps.DeleteFunc(resp.Header, func(name string, _ []string) bool {
					return strings.HasPrefix(name, "Access-Control-")
				})
			}

			// The rate limits of a backend are those of llmhop's upstream
			// credential, never of the client, whose limits llmhop reports.
			maps.DeleteFunc(resp.Header, func(name string, _ []string) bool {
				return strings.HasPrefix(name, "X-Ratelimit-")
			})

			return nil
		},
		ErrorHandler: proxyError,
		BufferPool:   &copyBuffers,
	}

	return md, nil
}

// serve proxies req to a server picked by the affinity of a once t holds
// its slots, waiting up to the queue timeout for them, or rejects it with 429,
// or 499 if its client left meanwhile.
func (m *model) serve(w http.ResponseWriter, req *http.Request, a *attempt, t *ticket) {
	admitted := m.queue.admit(req.Context(), t, m.queueTimeout)

	switch {
	case !admitted && req.Context().Err() != nil:
		w.WriteHeader(statusClientClosed)

		return
	case !admitted:
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "too_many_requests", "too many concurrent requests")

		return
	}

	defer t.release()

	m.pick(a)
	defer func() {
		entryOf(req).server = a.target.up.Label
		m.done(a)
	}()

	m.proxy.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), attemptKey{}, a)))
}

// probed records the latest probe of s. A failed one avoids s until a probe
// passes, which ends any avoidance and starts counting failures afresh.
func (m *model) probed(s *server, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	s.probed, s.probeFailed = true, err != nil

	if err == nil {
		s.avoidUntil, s.failures = time.Time{}, 0
	}
}

// healthy reports whether s passed its latest probe, regardless of the
// requests it failed, which may be those of one client alone.
func (m *model) healthy(s *server) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	return !s.probeFailed
}

// unprobed reports whether no probe of s reported yet, not even one of the
// router a reload replaced.
func (m *model) unprobed(s *server) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	return !s.probed
}

// address points req at t, joining the path of u onto the URL of t, with the
// configured headers and Host, else the one of req, and the rank of t.
func (m *model) address(req *http.Request, u url.URL, t *target) {
	host := req.Host
	req.URL = &u
	(&httputil.ProxyRequest{Out: req}).SetURL(t.up.URL)
	req.Host = cmp.Or(m.host, host)
	maps.Copy(req.Header, m.headers)

	if t.rank != "" {
		req.Header.Set(rankHeader, t.rank)
	}
}

// probe sends GET to the health path of the model on t.
func (m *model) probe(ctx context.Context, t *target) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.health, nil)
	if err != nil {
		return err
	}

	m.address(req, *req.URL, t)

	return t.up.Probe(req)
}
