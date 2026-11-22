package router

import (
	"cmp"
	"context"
	"maps"
	"math"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"golang.org/x/sync/semaphore"
	"golang.org/x/time/rate"

	"github.com/mirkolenz/llmhop/internal/config"
)

// Limits carries the admission limits, the state of the servers and the
// metrics from one router to the next, so that a reload neither resets nor
// doubles them while the requests of the previous router drain. A reload
// resizes the queues of models and the limiters of clients in place, while
// a byte budget whose size changes starts afresh. The zero value is ready
// to use.
type Limits struct {
	// mu guards the admission to the queues and the slots of clients.
	mu sync.Mutex
	// buffered is the budget of buffered request bodies of bufferedSize.
	buffered     *semaphore.Weighted
	bufferedSize int64
	queues       map[string]*queue
	pools        map[string]*pool
	// clients holds the limiters by client.
	clients map[string]*limiters
	// seq orders the tickets by arrival.
	seq     uint64
	metrics metrics
}

// bufferBudget returns the budget of buffered bytes, reusing that of a
// previous router of the same size. Zero means unlimited.
func (l *Limits) bufferBudget(size int64) *semaphore.Weighted {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.buffered == nil || l.bufferedSize != size {
		l.buffered, l.bufferedSize = semaphore.NewWeighted(cmp.Or(size, math.MaxInt64)), size
	}

	return l.buffered
}

// queue returns the queue of the model called name, resized to size.
func (l *Limits) queue(name string, size uint32) *queue {
	l.mu.Lock()
	defer l.mu.Unlock()

	q := getOrInsert(&l.queues, name, func() *queue { return &queue{limits: l, name: name, shares: make(map[string]*share)} })
	q.slots.size, q.retired = int64(size), false

	return q
}

// pool is the state of the servers of a model.
type pool struct {
	mu      sync.Mutex
	servers map[serverKey]*server
}

// serverKey identifies a server by its URL and health path, so that the
// probes of another path, or of none, never apply to it.
type serverKey struct{ url, health string }

// pool returns the pool of the model m called name with a server for each
// of its URLs, keeping the state of those it already had.
func (l *Limits) pool(name string, m config.Model) *pool {
	l.mu.Lock()
	defer l.mu.Unlock()

	p := getOrInsert(&l.pools, name, func() *pool { return &pool{} })
	servers := make(map[serverKey]*server, len(m.URLs))

	p.mu.Lock()
	defer p.mu.Unlock()

	for _, raw := range m.URLs {
		key := serverKey{raw, m.HealthPath}
		servers[key] = cmp.Or(p.servers[key], &server{})
	}

	p.servers = servers

	return p
}

// limiters returns the limiters of a client, resized to its policy.
func (l *Limits) limiters(client string, p config.Policy) *limiters {
	l.mu.Lock()
	defer l.mu.Unlock()

	lim := getOrInsert(&l.clients, client, func() *limiters { return &limiters{} })
	lim.slots.size = int64(deref(p.MaxConcurrentRequests))

	lim.mu.Lock()
	defer lim.mu.Unlock()

	now := time.Now()
	lim.requests.resize(float64(deref(p.RequestsPerMinute)), now)

	return lim
}

// retain retires the queues of the models that cfg no longer has, which
// stay until their requests finish, drops their pools and the limiters of
// the clients it no longer has, which the requests holding them keep for
// themselves, and admits the tickets that resized limits allow.
func (l *Limits) retain(cfg *config.Config) {
	l.mu.Lock()
	defer l.mu.Unlock()

	maps.DeleteFunc(l.pools, func(name string, _ *pool) bool {
		_, ok := cfg.Models[name]

		return !ok
	})

	for name, q := range l.queues {
		_, kept := cfg.Models[name]
		q.retired = !kept
		q.prune()
	}

	maps.DeleteFunc(l.clients, func(name string, _ *limiters) bool {
		_, ok := cfg.Clients[name]

		return !ok && (name != "" || cfg.RequiresAuth())
	})

	for _, q := range l.queues {
		q.dispatch()
	}
}

// ensure returns the map *m, creating it if nil.
func ensure[K comparable, V any](m *map[K]V) map[K]V {
	if *m == nil {
		*m = make(map[K]V)
	}

	return *m
}

// getOrInsert returns the value of key in *m, inserting the one of create
// if there is none.
func getOrInsert[K comparable, V any](m *map[K]V, key K, create func() V) V {
	v, ok := (*m)[key]
	if !ok {
		v = create()
		ensure(m)[key] = v
	}

	return v
}

// deref returns the value p points to, else the zero value.
func deref[T any](p *T) (v T) {
	if p != nil {
		v = *p
	}

	return v
}

// limiters bound the requests of a client. Limits guards its slots, and mu
// its buckets.
type limiters struct {
	slots    gauge
	mu       sync.Mutex
	requests bucket
}

// take admits a request to the request bucket of lim, taking a request if
// limited, and sets the rate limit headers, or answers 429 and reports
// false.
func take(w http.ResponseWriter, lim *limiters) bool {
	lim.mu.Lock()
	// Read under the lock, since a bucket never moves back in time.
	now := time.Now()
	wait := lim.requests.wait(now, 1)

	if wait == 0 && lim.requests.Limiter != nil {
		lim.requests.AllowN(now, 1)
	}

	level := lim.requests.level(now)
	lim.mu.Unlock()

	level.header(w.Header(), "Requests")

	if wait == 0 {
		return true
	}

	w.Header().Set("Retry-After", strconv.FormatFloat(math.Ceil(wait.Seconds()), 'f', 0, 64))
	writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "rate limit exceeded")

	return false
}

// gauge counts the requests in flight against a size, zero meaning unlimited.
type gauge struct {
	size, used int64
}

func (g *gauge) free() bool {
	return g.size == 0 || g.used < g.size
}

// bucket is a token bucket refilling its size per minute up to its size,
// nil meaning unlimited.
type bucket struct{ *rate.Limiter }

// resize keeps the level of a limited bucket, while one becoming limited
// starts full.
func (b *bucket) resize(size float64, now time.Time) {
	switch {
	case size == 0:
		b.Limiter = nil
	case b.Limiter == nil:
		b.Limiter = rate.NewLimiter(rate.Limit(size/60), int(size))
	default:
		b.SetLimitAt(now, rate.Limit(size/60))
		b.SetBurstAt(now, int(size))
	}
}

// wait returns how long until b holds need, zero if unlimited or already.
func (b *bucket) wait(now time.Time, need float64) time.Duration {
	if b.Limiter == nil {
		return 0
	}

	return time.Duration(max(0, need-b.TokensAt(now)) / float64(b.Limit()) * float64(time.Second))
}

// level is what the rate limit headers report of a bucket.
type level struct {
	limited         bool
	size, remaining float64
	reset           time.Duration
}

func (b *bucket) level(now time.Time) level {
	if b.Limiter == nil {
		return level{}
	}

	size := float64(b.Burst())

	return level{true, size, b.TokensAt(now), b.wait(now, size)}
}

// header sets the OpenAI rate limit headers of a kind for a limited bucket.
func (lv level) header(h http.Header, kind string) {
	if !lv.limited {
		return
	}

	h.Set("X-Ratelimit-Limit-"+kind, strconv.FormatFloat(lv.size, 'f', 0, 64))
	h.Set("X-Ratelimit-Remaining-"+kind, strconv.FormatFloat(math.Floor(max(0, lv.remaining)), 'f', 0, 64))
	h.Set("X-Ratelimit-Reset-"+kind, lv.reset.Round(time.Millisecond).String())
}

// queue admits the requests of a model, which wait while its slots or the
// limits of their client are exhausted. Waiting clients take turns weighted
// by their weight, by stride scheduling: the client with the lowest pass is
// admitted next and advances its pass by the inverse of its weight.
type queue struct {
	limits *Limits
	name   string
	slots  gauge
	// retired is a queue whose model a reload removed, which stays in
	// limits until its requests finish, so a released slot of their client
	// still admits them.
	retired bool
	// shares holds the waiting tickets by client, and running the number
	// of its admitted ones.
	shares  map[string]*share
	running map[string]int
	// pass is that of the latest admission, where a client starts waiting.
	pass float64
}

// share is the waiting tickets of one client in a queue, which share the
// slots of the client.
type share struct {
	pass    float64
	waiting []*ticket
}

// ticket is a request of a client waiting for its slots and those of the
// model, then holding them.
type ticket struct {
	client *client
	// queue is the one it waits in or holds.
	queue    *queue
	seq      uint64
	admitted bool
	ready    chan struct{}
}

// admit queues t until its slots are free, waiting up to timeout, and
// reports whether it holds them. A retired queue that was pruned meanwhile
// rejoins its limits, unless a reload re-added its model, whose queue then
// admits t, so that one queue holds every request of a name.
func (q *queue) admit(ctx context.Context, t *ticket, timeout time.Duration) bool {
	l := q.limits
	l.mu.Lock()
	q = getOrInsert(&l.queues, q.name, func() *queue { return q })
	s := q.enqueue(t)
	q.dispatch()
	l.mu.Unlock()

	if timeout > 0 {
		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		select {
		case <-t.ready:
		case <-ctx.Done():
		}
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if !t.admitted {
		q.leave(s, t)
		q.prune()
	}

	return t.admitted
}

// enqueue appends t to the share of its client, which starts at the pass of
// the latest admission.
func (q *queue) enqueue(t *ticket) *share {
	q.limits.seq++
	t.queue, t.seq, t.ready = q, q.limits.seq, make(chan struct{})

	s := getOrInsert(&q.shares, t.client.name, func() *share { return &share{pass: q.pass} })
	s.waiting = append(s.waiting, t)

	return s
}

// release frees the slots of t, which may admit another ticket of its queue
// or of its client in any queue.
func (t *ticket) release() {
	q := t.queue
	l := q.limits
	l.mu.Lock()
	defer l.mu.Unlock()

	q.slots.used--
	q.running[t.client.name]--
	t.client.slots.used--
	q.dispatch()

	for _, other := range l.queues {
		if _, waiting := other.shares[t.client.name]; waiting && other != q {
			other.dispatch()
		}
	}

	q.prune()
}

// prune drops a retired queue from its limits once no request waits in or
// holds it. Limits.mu must be held.
func (q *queue) prune() {
	if q.retired && q.slots.used == 0 && len(q.shares) == 0 {
		delete(q.limits.queues, q.name)
	}
}

// dispatch admits the waiting tickets while the slots allow, each time the
// first ticket of the client with the lowest pass whose slots are free, the
// earliest on a tie.
func (q *queue) dispatch() {
	for q.slots.free() {
		var next *ticket
		var from *share

		for _, s := range q.shares {
			t := s.waiting[0]
			if t.client.slots.free() && (next == nil || s.pass < from.pass || s.pass == from.pass && t.seq < next.seq) {
				next, from = t, s
			}
		}

		if next == nil {
			return
		}

		q.pass = from.pass
		from.pass += 1 / next.client.weight
		q.leave(from, next)
		q.slots.used++
		ensure(&q.running)[next.client.name]++
		next.client.slots.used++
		next.admitted = true
		close(next.ready)
	}
}

// leave removes t from its share, and the share once empty.
func (q *queue) leave(s *share, t *ticket) {
	s.waiting = slices.DeleteFunc(s.waiting, func(other *ticket) bool { return other == t })

	if len(s.waiting) == 0 {
		delete(q.shares, t.client.name)
	}
}

// occupancy is the requests of a model waiting for its slots and those
// holding them by client.
type occupancy struct {
	waiting int
	running map[string]int
}

// occupancy returns the occupancy of each of models.
func (l *Limits) occupancy(models []*model) []occupancy {
	l.mu.Lock()
	defer l.mu.Unlock()

	out := make([]occupancy, len(models))

	for i, m := range models {
		for _, s := range m.queue.shares {
			out[i].waiting += len(s.waiting)
		}

		out[i].running = maps.Clone(m.queue.running)
	}

	return out
}
