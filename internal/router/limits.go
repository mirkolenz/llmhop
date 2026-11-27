package router

import (
	"cmp"
	"maps"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"golang.org/x/sync/semaphore"

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
	seq   uint64
	stats stats
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
	lim.tokens.resize(float64(deref(p.TokensPerMinute)), now)
	lim.seconds.resize(float64(deref(p.SlotSecondsPerMinute)), now)

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

// limiters bound the requests of a client. Limits guards the size of its
// slots, both locks their use, and mu its buckets and the slot seconds.
type limiters struct {
	slots                     gauge
	mu                        sync.Mutex
	requests, tokens, seconds bucket
	// held is the slot seconds of its requests until settled.
	held    float64
	settled time.Time
}

// hold changes the slots in use by delta, which drain the slot seconds of
// lim from now on. Limits.mu must be held.
func (lim *limiters) hold(delta int64) {
	lim.mu.Lock()
	defer lim.mu.Unlock()

	now := time.Now()
	lim.settle(now)
	lim.slots.used += delta
	lim.seconds.setDrain(now, float64(lim.slots.used)*60)
}

// settle adds the slot seconds held until now. lim.mu must be held.
func (lim *limiters) settle(now time.Time) {
	lim.held += float64(lim.slots.used) * max(0, now.Sub(lim.settled).Seconds())
	lim.settled = now
}

// take admits a request while each bucket of lim holds n, taking n requests,
// and sets the rate limit headers, or answers 429 and reports false. The
// tokens and slot seconds of the request are charged once they flow, so a
// request takes one of each before it queues and none once admitted, when
// only a bucket that fell into debt meanwhile rejects it.
func take(w http.ResponseWriter, lim *limiters, n float64) bool {
	lim.mu.Lock()
	// Read under the lock, since a bucket never moves back in time.
	now := time.Now()
	wait := max(lim.requests.wait(now, n), lim.tokens.wait(now, n), lim.seconds.wait(now, n))

	if wait == 0 {
		lim.requests.take(now, n)
	}

	requests, tokens, seconds := lim.requests.level(now), lim.tokens.level(now), lim.seconds.level(now)
	lim.mu.Unlock()

	requests.header(w.Header(), "Requests")
	tokens.header(w.Header(), "Tokens")
	seconds.header(w.Header(), "Slot-Seconds")

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

// charge takes n tokens from the token bucket of lim, which may fall into
// debt.
func (lim *limiters) charge(n int64) {
	lim.mu.Lock()
	defer lim.mu.Unlock()

	lim.tokens.take(time.Now(), float64(n))
}

// forfeit takes the whole size of the token bucket of lim.
func (lim *limiters) forfeit() {
	lim.mu.Lock()
	defer lim.mu.Unlock()

	lim.tokens.take(time.Now(), lim.tokens.size)
}

// bucket is a token bucket refilling its size per minute up to its size,
// whose level falls below zero once it is charged more than it holds. A
// zero size means unlimited.
type bucket struct {
	size, tokens float64
	// drain empties it continuously by that much per minute.
	drain float64
	// at is when tokens was last set.
	at time.Time
}

// resize keeps the level of a limited bucket, while one becoming limited
// starts full.
func (b *bucket) resize(size float64, now time.Time) {
	tokens := size

	if b.size > 0 {
		tokens = min(b.tokensAt(now), size)
	}

	b.size, b.tokens, b.at = size, tokens, now
}

// tokensAt returns the level of b at now.
func (b *bucket) tokensAt(now time.Time) float64 {
	return min(b.size, b.tokens+max(0, now.Sub(b.at).Minutes())*(b.size-b.drain))
}

// setDrain sets the drain of b from now on, after the old one drained it.
func (b *bucket) setDrain(now time.Time, drain float64) {
	b.take(now, 0)
	b.drain = drain
}

// take takes n from a limited bucket, bringing its level up to now.
func (b *bucket) take(now time.Time, n float64) {
	if b.size > 0 {
		b.tokens, b.at = b.tokensAt(now)-n, now
	}
}

// wait returns how long until b holds need, zero if unlimited or already,
// as if a drain at least as fast as the refill stopped.
func (b *bucket) wait(now time.Time, need float64) time.Duration {
	if b.size == 0 {
		return 0
	}

	refill := b.size - b.drain

	if refill <= 0 {
		refill = b.size
	}

	return time.Duration(max(0, need-b.tokensAt(now)) / refill * float64(time.Minute))
}

// level is what the rate limit headers report of a bucket.
type level struct {
	limited         bool
	size, remaining float64
	reset           time.Duration
}

func (b *bucket) level(now time.Time) level {
	if b.size == 0 {
		return level{}
	}

	return level{true, b.size, b.tokensAt(now), b.wait(now, b.size)}
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

// clientLimits is the size of the slots of a client, zero meaning
// unlimited, the levels of its buckets and the slot seconds it held.
type clientLimits struct {
	slots                     int64
	requests, tokens, seconds level
	held                      float64
}

// clientLimits returns the limits of each client.
func (l *Limits) clientLimits() map[string]clientLimits {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	out := make(map[string]clientLimits, len(l.clients))

	for name, lim := range l.clients {
		lim.mu.Lock()
		lim.settle(now)
		out[name] = clientLimits{lim.slots.size, lim.requests.level(now), lim.tokens.level(now), lim.seconds.level(now), lim.held}
		lim.mu.Unlock()
	}

	return out
}
