package router

import (
	"context"
	"crypto/sha256"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/mirkolenz/llmhop/internal/config"
)

// clientHeader tells a backend the name of the client of a request.
// Only llmhop sets it, see the proxy's Rewrite.
const clientHeader = "X-Llmhop-Client"

// authenticator checks bearer tokens against the keys of the clients, and
// names the requests of client listeners without one.
type authenticator struct {
	// keys maps the SHA-256 digest of each key to its client.
	keys map[[sha256.Size]byte]*client
	// listeners maps the name of each client listener to its client.
	listeners map[string]*client
	// anonymous is the client of every request without any configured.
	anonymous *client
	// crossOrigin rejects the cross-site requests of browsers.
	crossOrigin *http.CrossOriginProtection
}

func newAuthenticator(cfg *config.Config, limits *Limits) *authenticator {
	a := &authenticator{
		keys:        make(map[[sha256.Size]byte]*client),
		listeners:   make(map[string]*client),
		crossOrigin: http.NewCrossOriginProtection(),
	}

	if !cfg.RequiresAuth() {
		a.anonymous = newClient(cfg, "", config.Client{}, limits)
	}

	for name, c := range cfg.Clients {
		cl := newClient(cfg, name, c, limits)

		if c.Listener != "" {
			a.listeners[c.Listener] = cl
		} else {
			a.keys[sha256.Sum256([]byte(c.Key))] = cl
		}
	}

	return a
}

// wrap gates next with the clients, which their policy may still turn away,
// and strips the client Authorization header before it reaches any backend.
func (a *authenticator) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if a.anonymous != nil {
			entryOf(req).client = a.anonymous
			next.ServeHTTP(w, req)

			return
		}

		c, onListener := a.socketClient(req)

		if onListener && !a.sameOrigin(req) {
			writeError(w, http.StatusForbidden, "cross_origin", "client listeners only serve same-origin requests to loopback hosts")

			return
		}

		if !onListener {
			var ok bool

			if c, ok = a.bearerClient(req); !ok {
				unauthorized(w, "invalid_api_key", "missing or invalid bearer token")

				return
			}
		}

		entryOf(req).client = c

		if !c.admits(w) {
			return
		}

		req.Header.Del("Authorization")
		next.ServeHTTP(w, req)
	})
}

// unauthorized answers 401 with the Bearer challenge that HTTP requires.
func unauthorized(w http.ResponseWriter, code, message string) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeError(w, http.StatusUnauthorized, code, message)
}

// bearerClient returns the client of the token of req. A token outside the
// Bearer scheme never counts, even if known.
func (a *authenticator) bearerClient(req *http.Request) (*client, bool) {
	token, ok := bearer(req.Header.Get("Authorization"))
	if !ok {
		return nil, false
	}

	return a.lookup(token)
}

// sameOrigin admits other clients than browsers and the requests of browsers
// to a loopback host, which DNS rebinding cannot reach, that are no
// cross-site requests, since web pages may use a client listener forwarded to
// a local port.
func (a *authenticator) sameOrigin(req *http.Request) bool {
	return (req.Host == "" || loopbackHost(req.Host)) && a.crossOrigin.Check(req) == nil
}

// socketClient returns the client of the client listener req arrived on,
// which counts only as a unix socket.
func (a *authenticator) socketClient(req *http.Request) (*client, bool) {
	if _, ok := req.Context().Value(http.LocalAddrContextKey).(*net.UnixAddr); !ok {
		return nil, false
	}

	c, ok := a.listeners[listenerOf(req)]

	return c, ok
}

type listenerKey struct{}

// WithListener names the listener of the requests of ctx, the base context
// of the connections a server accepts from it.
func WithListener(ctx context.Context, name string) context.Context {
	return context.WithValue(ctx, listenerKey{}, name)
}

// listenerOf returns the name of the listener req arrived on.
func listenerOf(req *http.Request) string {
	name, _ := req.Context().Value(listenerKey{}).(string)

	return name
}

// loopbackHost reports whether a host with an optional port is localhost or
// a loopback IP address.
func loopbackHost(hostport string) bool {
	host := strings.TrimSuffix(strings.ToLower((&url.URL{Host: hostport}).Hostname()), ".")

	return host == "localhost" || strings.HasSuffix(host, ".localhost") || net.ParseIP(host).IsLoopback()
}

// lookup returns the client of token by its digest, so the timing of the
// lookup reveals nothing about the keys.
func (a *authenticator) lookup(token string) (*client, bool) {
	c, ok := a.keys[sha256.Sum256([]byte(token))]

	return c, ok
}

// bearer returns the token of header if it is "Bearer <token>", whose scheme
// is case-insensitive (RFC 9110, 11.1).
func bearer(header string) (string, bool) {
	scheme, token, ok := strings.Cut(header, " ")

	return token, ok && strings.EqualFold(scheme, "Bearer")
}
