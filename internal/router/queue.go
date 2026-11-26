package router

import (
	"context"
	"maps"
	"slices"
	"time"
)

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
	// slots is the size of its slots, zero meaning unlimited.
	slots int64
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
		out[i].slots = m.queue.slots.size
	}

	return out
}
