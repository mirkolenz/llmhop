package router

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/mirkolenz/llmhop/internal/config"
)

// clientHeader tells a backend the name of the auth token of a request.
// Only llmhop sets it, see the proxy's Rewrite.
const clientHeader = "X-Llmhop-Client"

// authenticator checks bearer tokens against the auth tokens by name.
type authenticator struct {
	tokens map[string][]byte
}

func newAuthenticator(cfg *config.Config) *authenticator {
	a := &authenticator{tokens: make(map[string][]byte, len(cfg.AuthTokens))}

	for name, token := range cfg.AuthTokens {
		a.tokens[name] = []byte(token)
	}

	return a
}

// wrap gates next with the bearer tokens and strips the client
// Authorization header before it reaches any backend.
func (a *authenticator) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		token, ok := bearer(req.Header.Get("Authorization"))
		name, known := a.lookup(token)

		// A token outside the Bearer scheme never counts, even if known.
		if !ok || !known {
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeError(w, http.StatusUnauthorized, "invalid_api_key", "missing or invalid bearer token")

			return
		}

		entryOf(req).client = name
		req.Header.Del("Authorization")
		next.ServeHTTP(w, req)
	})
}

// lookup returns the name of token. Comparison is constant-time to avoid
// leaking token contents via timing.
func (a *authenticator) lookup(token string) (string, bool) {
	got := []byte(token)

	for name, t := range a.tokens {
		if subtle.ConstantTimeCompare(got, t) == 1 {
			return name, true
		}
	}

	return "", false
}

// bearer returns the token of header if it is "Bearer <token>", whose scheme
// is case-insensitive (RFC 9110, 11.1).
func bearer(header string) (string, bool) {
	scheme, token, ok := strings.Cut(header, " ")

	return token, ok && strings.EqualFold(scheme, "Bearer")
}
