package router

import (
	"crypto/subtle"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/mirkolenz/llmhop/internal/config"
)

// clientHeader tells a backend the name of the auth token of a request.
// Only llmhop sets it, see the proxy's Rewrite.
const clientHeader = "X-Llmhop-Client"

// authenticator checks bearer tokens against the auth tokens by name, and
// names the requests of trusted sockets without one.
type authenticator struct {
	tokens map[string][]byte
	// sockets maps the path of each trusted socket to its client name.
	sockets map[string]string
	// crossOrigin rejects the cross-site requests of browsers.
	crossOrigin *http.CrossOriginProtection
}

func newAuthenticator(cfg *config.Config) *authenticator {
	a := &authenticator{
		tokens:      make(map[string][]byte, len(cfg.AuthTokens)),
		sockets:     make(map[string]string, len(cfg.TrustedSockets)),
		crossOrigin: http.NewCrossOriginProtection(),
	}

	for name, token := range cfg.AuthTokens {
		a.tokens[name] = []byte(token)
	}

	for name, socket := range cfg.TrustedSockets {
		a.sockets[socket] = name
	}

	return a
}

// wrap gates next with the bearer tokens and strips the client
// Authorization header before it reaches any backend.
func (a *authenticator) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		name, trusted := a.socketClient(req)

		if trusted && !a.sameOrigin(req) {
			writeError(w, http.StatusForbidden, "cross_origin", "trusted sockets only serve same-origin requests to loopback hosts")

			return
		}

		if !trusted {
			var ok bool

			if name, ok = a.bearerClient(req); !ok {
				w.Header().Set("WWW-Authenticate", "Bearer")
				writeError(w, http.StatusUnauthorized, "invalid_api_key", "missing or invalid bearer token")

				return
			}
		}

		entryOf(req).client = name
		req.Header.Del("Authorization")
		next.ServeHTTP(w, req)
	})
}

// bearerClient returns the name of the token of req. A token outside the
// Bearer scheme never counts, even if known.
func (a *authenticator) bearerClient(req *http.Request) (string, bool) {
	token, ok := bearer(req.Header.Get("Authorization"))
	if !ok {
		return "", false
	}

	return a.lookup(token)
}

// sameOrigin admits other clients than browsers and the requests of browsers
// to a loopback host, which DNS rebinding cannot reach, that are no
// cross-site requests, since web pages may use a trusted socket forwarded to
// a local port.
func (a *authenticator) sameOrigin(req *http.Request) bool {
	return (req.Host == "" || loopbackHost(req.Host)) && a.crossOrigin.Check(req) == nil
}

// socketClient returns the client name of the trusted socket req arrived on.
func (a *authenticator) socketClient(req *http.Request) (string, bool) {
	addr, ok := req.Context().Value(http.LocalAddrContextKey).(*net.UnixAddr)
	if !ok {
		return "", false
	}

	name, ok := a.sockets[addr.Name]

	return name, ok
}

// loopbackHost reports whether a host with an optional port is localhost or
// a loopback IP address.
func loopbackHost(hostport string) bool {
	host := strings.TrimSuffix(strings.ToLower((&url.URL{Host: hostport}).Hostname()), ".")

	return host == "localhost" || strings.HasSuffix(host, ".localhost") || net.ParseIP(host).IsLoopback()
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
