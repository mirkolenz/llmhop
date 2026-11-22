package router

import (
	"cmp"
	"context"
	"errors"
	"hash/fnv"
	"io"
	"log/slog"
	"maps"
	"net"
	"net/http"
	"net/http/httputil"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/semaphore"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// rankHeader pins a request to one data-parallel rank of a vLLM or SGLang
// server.
const rankHeader = "X-Data-Parallel-Rank"

// model is a configured model with the servers serving it. Its in-flight
// counts and health only exist to spread the requests of this process, so
// every instance of llmhop decides alone and none shares state.
type model struct {
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
	// slots bounds the proxied requests over all servers.
	slots        *semaphore.Weighted
	queueTimeout time.Duration
	failover     time.Duration
	proxy        *httputil.ReverseProxy

	// mu guards the in-flight counts and health of every server and target.
	mu sync.Mutex
}

// server is one URL of a model.
type server struct {
	up        *upstream.Upstream
	inflight  int
	downUntil time.Time
}

// target is a server or one of its data-parallel ranks.
type target struct {
	*server
	rank string
	// id seeds the rendezvous hash, the same in every llmhop instance.
	id uint64
}

// newModel builds the model of m. With stripCORS, llmhop alone decides which
// pages may read a response, as it does whenever tokens are required.
func newModel(m config.Model, slots *semaphore.Weighted, stripCORS bool) (*model, error) {
	headers := make(http.Header, len(m.Headers))

	for k, v := range m.Headers {
		headers.Set(k, v)
	}

	md := &model{
		headers:      headers,
		host:         headers.Get("Host"),
		health:       m.HealthPath,
		slots:        slots,
		queueTimeout: time.Duration(m.QueueTimeoutSeconds) * time.Second,
		failover:     time.Duration(m.FailoverSeconds) * time.Second,
	}
	headers.Del("Host")

	for _, raw := range m.URLs {
		up, err := upstream.Parse(raw, time.Duration(m.ResponseTimeoutSeconds)*time.Second)
		if err != nil {
			return nil, err
		}

		s := &server{up: up}
		whole := &target{server: s, id: hashOf(raw)}
		md.servers = append(md.servers, whole)

		// Unset is zero, a single rank like one.
		if m.DataParallelSize < 2 {
			md.targets = append(md.targets, whole)
			continue
		}

		for rank := range m.DataParallelSize {
			r := strconv.FormatUint(uint64(rank), 10)
			md.targets = append(md.targets, &target{server: s, rank: r, id: hashOf(raw, r)})
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

			if client := entryOf(r.In).client; client != "" {
				r.Out.Header.Set(clientHeader, client)
			}
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

			return nil
		},
		ErrorHandler: proxyError,
	}

	return md, nil
}

// acquire takes a slot, waiting up to the queue timeout for one, or rejects
// the request with 429 and reports false.
func (m *model) acquire(w http.ResponseWriter, req *http.Request) bool {
	if m.slots.TryAcquire(1) {
		return true
	}

	if m.queueTimeout > 0 {
		ctx, cancel := context.WithTimeout(req.Context(), m.queueTimeout)
		defer cancel()

		if m.slots.Acquire(ctx, 1) == nil {
			return true
		}
	}

	w.Header().Set("Retry-After", "1")
	writeError(w, http.StatusTooManyRequests, "too_many_requests", "too many concurrent requests for this model")

	return false
}

// serve proxies req to a server picked by its affinity once it holds a slot.
func (m *model) serve(w http.ResponseWriter, req *http.Request, aff affinity) {
	if !m.acquire(w, req) {
		return
	}

	defer m.slots.Release(1)

	a := &attempt{affinity: aff, target: m.pick(aff, nil)}
	defer func() {
		entryOf(req).server = a.target.up.Label
		m.release(a.target)
	}()

	m.proxy.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), attemptKey{}, a)))
}

// pick takes a target for a request, skipping the servers tried before. A
// keyed request takes the first target in the rendezvous order of its key,
// the same in every llmhop instance, and a keyless one the least busy
// server, leaving the choice of a rank to the server. Servers that refused a
// connection recently serve only once no other one can. It returns nil once
// every server was tried.
func (m *model) pick(a affinity, tried []*server) *target {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()
	candidates := m.servers
	// The best candidate scores highest, the first one on a tie.
	score := func(t *target) uint64 { return ^uint64(t.inflight) }

	if a.keyed {
		candidates = m.targets
		score = func(t *target) uint64 { return mix(a.key ^ t.id) }
	}

	// The second pass relaxes the health.
	for pass := range 2 {
		var best *target

		for _, t := range candidates {
			eligible := !slices.Contains(tried, t.server) && (pass > 0 || now.After(t.downUntil))
			if eligible && (best == nil || score(t) > score(best)) {
				best = t
			}
		}

		if best != nil {
			best.inflight++

			return best
		}
	}

	return nil
}

// release ends a request picked for t.
func (m *model) release(t *target) {
	m.mu.Lock()
	defer m.mu.Unlock()

	t.inflight--
}

// fail avoids s for the failover duration.
func (m *model) fail(s *server) {
	m.mu.Lock()
	defer m.mu.Unlock()

	s.downUntil = time.Now().Add(m.failover)
}

// address points req at s, joining its path onto the URL of s, with the
// configured headers and Host, else host.
func (m *model) address(req *http.Request, s *server, host string) {
	(&httputil.ProxyRequest{Out: req}).SetURL(s.up.URL)
	req.Host = cmp.Or(m.host, host)

	for k, v := range m.headers {
		req.Header[k] = v
	}
}

// attempt is the routing of one proxied request, which the transport of its
// model may move to another server.
type attempt struct {
	affinity
	target *target
	tried  []*server
}

type attemptKey struct{}

// RoundTrip sends out to the target of its attempt. A server refusing the
// connection is avoided for a while, and a body that can be resent moves on
// to the next server.
func (m *model) RoundTrip(out *http.Request) (*http.Response, error) {
	a := out.Context().Value(attemptKey{}).(*attempt)

	for {
		resp, err := m.send(out, a.target)

		// Only a failed dial certainly left the request unsent, and one
		// the client cancelled says nothing about the server.
		if opErr, ok := errors.AsType[*net.OpError](err); !ok || opErr.Op != "dial" || out.Context().Err() != nil {
			return resp, err
		}

		m.fail(a.target.server)
		a.tried = append(a.tried, a.target.server)

		if out.Body != nil && out.GetBody == nil {
			return nil, err
		}

		next := m.pick(a.affinity, a.tried)
		if next == nil {
			return nil, err
		}

		m.release(a.target)
		a.target = next

		if out.GetBody != nil {
			if out.Body, err = out.GetBody(); err != nil {
				return nil, err
			}
		}
	}
}

// send sends out to t, pinned to the rank of t if it has one.
func (m *model) send(out *http.Request, t *target) (*http.Response, error) {
	req := out.Clone(out.Context())
	m.address(req, t.server, out.Host)

	if t.rank != "" {
		req.Header.Set(rankHeader, t.rank)
	}

	return t.up.Transport.RoundTrip(req)
}

// ready reports whether any server of the model answers on its health
// path, probing them concurrently and cancelling the rest once one answers.
func (m *model) ready(ctx context.Context) bool {
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(errAnswered)

	// Buffered, so that the cancelled probes never block.
	failed := make(chan bool, len(m.servers))

	for _, t := range m.servers {
		go func() {
			err := m.probe(ctx, t.server)
			if err != nil && context.Cause(ctx) != errAnswered {
				slog.Warn("readiness", "server", t.up.Label, "err", err)
			}

			failed <- err != nil
		}()
	}

	for range m.servers {
		if !<-failed {
			return true
		}
	}

	return false
}

// errAnswered cancels the probes of a model that another server answered.
var errAnswered = errors.New("another server answered")

// probe sends GET to the health path of the model on s.
func (m *model) probe(ctx context.Context, s *server) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.health, nil)
	if err != nil {
		return err
	}

	m.address(req, s, "")

	return s.up.Probe(req)
}

// hashOf hashes parts with FNV-1a, separated so that they cannot shift.
func hashOf(parts ...string) uint64 {
	h := fnv.New64a()

	for _, p := range parts {
		_, _ = io.WriteString(h, p)
		_, _ = h.Write([]byte{0})
	}

	return h.Sum64()
}

// mix is the finalizer of SplitMix64, which spreads a key and target id
// into a uniform rendezvous score.
func mix(x uint64) uint64 {
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	x ^= x >> 31

	return x
}
