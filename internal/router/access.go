package router

import (
	"bufio"
	"context"
	"crypto/rand"
	"log/slog"
	"net"
	"net/http"
	"time"
)

// requestIDHeader identifies a request in the access log and to backends
// such as vLLM, which adopt it. A client may set it.
const requestIDHeader = "X-Request-Id"

// entry collects what the access log and the metrics report beyond the
// request itself.
type entry struct {
	client *client
	// model is the requested name, and served that of the model serving it.
	model  string
	served string
	server string
}

// names returns the names of the client of e and its policy.
func (e *entry) names() (client, policy string) {
	if e.client == nil {
		return "", ""
	}

	return e.client.name, e.client.policy
}

type entryKey struct{}

// entryOf returns the log entry of req, which carries its client, so a
// request outside logRequests is a wiring bug.
func entryOf(req *http.Request) *entry {
	e, ok := req.Context().Value(entryKey{}).(*entry)
	if !ok {
		panic("router: request outside logRequests")
	}

	return e
}

// logRequests assigns every request an ID, unless it carries one, and logs
// and counts it once answered. Durations are in seconds.
func logRequests(next http.Handler, met *metrics) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		start := time.Now()
		// Path routing strips the prefix in place.
		method, path := req.Method, req.URL.Path

		id := req.Header.Get(requestIDHeader)
		if id == "" {
			id = rand.Text()
			req.Header.Set(requestIDHeader, id)
		}

		w.Header().Set(requestIDHeader, id)

		e := &entry{}
		rec := &recorder{ResponseWriter: w, id: id}

		// Deferred, since ReverseProxy panics once the client aborts.
		defer func() {
			client, policy := e.names()
			slog.LogAttrs(req.Context(), slog.LevelInfo, "request",
				slog.String("id", id),
				slog.String("method", method),
				slog.String("path", path),
				slog.Int("status", rec.status()),
				slog.Int64("bytes", rec.bytes),
				slog.Float64("duration", time.Since(start).Seconds()),
				slog.String("client", client),
				slog.String("policy", policy),
				slog.String("model", e.model),
				slog.String("server", e.server),
			)
			met.request(e, rec.status())
		}()

		next.ServeHTTP(rec, req.WithContext(context.WithValue(req.Context(), entryKey{}, e)))
	})
}

// recorder notes the status and body size of a response. Unwrap lets
// flushing reach the wrapped writer.
type recorder struct {
	http.ResponseWriter
	// id is the request ID, which the final response carries even after an
	// informational one, after which ReverseProxy clears the header map.
	id    string
	code  int
	bytes int64
}

func (r *recorder) WriteHeader(code int) {
	if r.code == 0 && code >= 200 {
		r.code = code
		r.Header().Set(requestIDHeader, r.id)
	}

	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(p []byte) (int, error) {
	n, err := r.ResponseWriter.Write(p)
	r.bytes += int64(n)

	return n, err
}

// Hijack notes the 101 that ReverseProxy writes to the hijacked connection
// when switching protocols, bypassing WriteHeader.
func (r *recorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, brw, err := http.NewResponseController(r.ResponseWriter).Hijack()
	if err == nil && r.code == 0 {
		r.code = http.StatusSwitchingProtocols
	}

	return conn, brw, err
}

func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func (r *recorder) status() int {
	if r.code == 0 {
		return http.StatusOK
	}

	return r.code
}
