// Package authz validates incoming bearer tokens for the router.
package authz

import (
	"crypto/subtle"
	"strings"
)

// CheckBearer reports whether header carries a "Bearer <token>" matching any
// of the configured tokens. Comparison is constant-time to avoid leaking
// token contents via timing.
func CheckBearer(header string, tokens [][]byte) bool {
	got, ok := strings.CutPrefix(header, "Bearer ")
	if !ok {
		return false
	}
	gotB := []byte(got)
	for _, t := range tokens {
		if subtle.ConstantTimeCompare(gotB, t) == 1 {
			return true
		}
	}
	return false
}
