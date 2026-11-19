package router

import (
	"cmp"
	"math"
	"sync"

	"golang.org/x/sync/semaphore"
)

// Limits carries the admission limits from one router to the next, so that a
// reload neither resets nor doubles them while the requests of the previous
// router drain. A limit whose size changes starts afresh. The zero value is
// ready to use.
type Limits struct {
	mu   sync.Mutex
	sems map[string]limit
}

type limit struct {
	size int64
	sem  *semaphore.Weighted
}

// newSemaphore returns a semaphore of size n, where zero means unlimited.
func newSemaphore(n int64) *semaphore.Weighted {
	return semaphore.NewWeighted(cmp.Or(n, math.MaxInt64))
}

// semaphore returns the semaphore of key, reusing that of a previous router
// of the same size. Zero means unlimited.
func (l *Limits) semaphore(key string, size int64) *semaphore.Weighted {
	l.mu.Lock()
	defer l.mu.Unlock()

	if lim, ok := l.sems[key]; ok && lim.size == size {
		return lim.sem
	}

	if l.sems == nil {
		l.sems = make(map[string]limit)
	}

	sem := newSemaphore(size)
	l.sems[key] = limit{size, sem}

	return sem
}
