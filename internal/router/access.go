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

// entry collects what the access log reports beyond the request itself.
type entry struct {
	client string
	model  string
	server string
}

type entryKey struct{}

// entryOf returns the log entry of req, or a discarded one outside the log.
func entryOf(req *http.Request) *entry {
	if e, ok := req.Context().Value(entryKey{}).(*entry); ok {
		return e
	}

	return &entry{}
}

// logRequests assigns every request an ID, unless it carries one, and logs
// it once answered.
func logRequests(next http.Handler) http.Handler {
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
		next.ServeHTTP(rec, req.WithContext(context.WithValue(req.Context(), entryKey{}, e)))

		slog.Info("request",
			"id", id,
			"method", method,
			"path", path,
			"status", rec.status(),
			"bytes", rec.bytes,
			"duration", time.Since(start).Round(time.Millisecond),
			"client", e.client,
			"model", e.model,
			"server", e.server,
		)
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
