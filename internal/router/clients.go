package router

import (
	"cmp"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
)

// matcher resolves a name to the value of the name itself, else of the
// longest wildcard prefixing it.
type matcher[T any] struct {
	exact map[string]T
	// patterns holds the wildcards, the longest prefix first.
	patterns []pattern[T]
}

type pattern[T any] struct {
	prefix string
	value  T
}

// add adds a name or wildcard, keeping the longest prefix first.
func (m *matcher[T]) add(name string, value T) {
	prefix, ok := config.Pattern(name)
	if !ok {
		ensure(&m.exact)[name] = value

		return
	}

	i, _ := slices.BinarySearchFunc(m.patterns, len(prefix), func(p pattern[T], n int) int { return cmp.Compare(n, len(p.prefix)) })
	m.patterns = slices.Insert(m.patterns, i, pattern[T]{prefix, value})
}

func (m *matcher[T]) lookup(name string) (T, bool) {
	if v, ok := m.exact[name]; ok {
		return v, true
	}

	for _, p := range m.patterns {
		if strings.HasPrefix(name, p.prefix) {
			return p.value, true
		}
	}

	var zero T

	return zero, false
}

// client is the effective policy of a client with its limiters.
type client struct {
	name      string
	policy    string
	expiresAt time.Time
	*limiters
	// models are the models it may use, every one if nil.
	models *matcher[struct{}]
	weight float64
}

// newClient resolves the effective policy of a client of cfg against the
// limits shared across reloads.
func newClient(cfg *config.Config, name string, cc config.Client, limits *Limits) *client {
	p := cfg.EffectivePolicy(cc)
	c := &client{
		name:      name,
		policy:    cc.PolicyName,
		expiresAt: cc.ExpiresAt,
		limiters:  limits.limiters(name, p),
		weight:    float64(cmp.Or(deref(p.Weight), 1)),
	}

	if len(p.Models) > 0 {
		c.models = &matcher[struct{}]{}

		for _, pattern := range p.Models {
			c.models.add(pattern, struct{}{})
		}
	}

	return c
}

// allows reports whether c may use a model.
func (c *client) allows(model string) bool {
	if c.models == nil {
		return true
	}

	_, ok := c.models.lookup(model)

	return ok
}

// admits answers a request of c once it expired and reports false.
func (c *client) admits(w http.ResponseWriter) bool {
	if !c.expiresAt.IsZero() && time.Now().After(c.expiresAt) {
		unauthorized(w, "key_expired", "the key of this client expired")

		return false
	}

	return true
}
