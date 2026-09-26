// Package authz validates incoming bearer tokens for the router.
package authz

import (
	"crypto/subtle"
	"strings"
)

// CheckBearer reports whether header carries a "Bearer <token>" matching any
// of the configured tokens. The scheme is case-insensitive (RFC 9110, 11.1).
// Comparison is constant-time to avoid leaking token contents via timing.
func CheckBearer(header string, tokens [][]byte) bool {
	scheme, got, ok := strings.Cut(header, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
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
