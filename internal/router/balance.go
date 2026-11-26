package router

import (
	"hash/fnv"
	"io"
	"math"
	"slices"
	"time"
)

// ejectAfter is how many failed requests in a row make a server avoided.
const ejectAfter = 3

// outcome is what a request tells about its server.
type outcome uint8

const (
	// unknown is the outcome of a request not sent or cancelled by its client.
	unknown outcome = iota
	succeeded
	failed
	// refused is a failed dial, which avoids a server at once.
	refused
)

// pick records the outcome of the current target of a, then moves a to the
// best target it has not tried and reports whether there was one. A keyed
// request takes the first target in the rendezvous order of its key, the
// same in every llmhop instance, and a keyless one the least busy server,
// leaving the choice of a rank to the server. A server serves only once no
// other one can if it is avoided, and a keyed request skips one beyond 1.25
// times the average load plus one, as in consistent hashing with bounded
// loads. A pinned request takes its first target regardless and never
// moves, since no other server holds its state.
func (m *model) pick(a *attempt) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()

	if a.target != nil {
		m.record(a.target.server, a.outcome, now)
		a.outcome = unknown
		a.tried = append(a.tried, a.target.server)

		if a.pinned {
			return false
		}
	}

	candidates := m.servers
	// The best candidate scores highest, the first one on a tie.
	score := func(t *target) uint64 { return ^uint64(t.inflight) }
	// The least busy server never exceeds the bound, which only keyed
	// requests need.
	bound := math.MaxInt

	if a.keyed {
		candidates = m.targets
		score = func(t *target) uint64 { return mix(a.key ^ t.id) }

		// The bound is ceil(1.25 * average in-flight) + 1.
		load, n := 0, 4*len(m.servers)

		for _, t := range m.servers {
			load += t.inflight
		}

		bound = (5*load+n-1)/n + 1
	}

	// Health ranks above the bound, which ranks above the score.
	var best *target
	var bestTier int
	var bestScore uint64

	for _, t := range candidates {
		if slices.Contains(a.tried, t.server) {
			continue
		}

		tier := 0

		if !t.avoided(now) {
			tier += 2
		}

		if t.inflight <= bound {
			tier++
		}

		// A pinned request ranks by its score alone.
		if a.pinned {
			tier = 0
		}

		if s := score(t); best == nil || tier > bestTier || tier == bestTier && s > bestScore {
			best, bestTier, bestScore = t, tier, s
		}
	}

	if best == nil {
		return false
	}

	if a.target != nil {
		a.target.inflight--
	}

	best.inflight++
	a.target = best

	return true
}

// done records the outcome of the target of a and ends its request.
func (m *model) done(a *attempt) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.record(a.target.server, a.outcome, time.Now())
	a.target.inflight--
}

// record notes the outcome of a request to s. A refused dial avoids s for
// the failover duration at once, other failures once s failed ejectAfter
// requests in a row. m.mu must be held.
func (m *model) record(s *server, o outcome, now time.Time) {
	switch o {
	case unknown:
	case succeeded:
		s.failures = 0
	default:
		s.failures++

		if o == refused || s.failures >= ejectAfter {
			s.avoidUntil = now.Add(m.failover)
		}
	}
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
