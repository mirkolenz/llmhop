// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers, selected by the /route/{model} path prefix or the JSON
// "model" field.
package router

import (
	"cmp"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptrace"
	"net/http/httputil"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// New returns an http.Handler that serves the OpenAI models API from the
// configured models and proxies every other request to the backend named by
// its /route/{model} path prefix or else its JSON "model" field, all guarded
// by the configured auth tokens. Only GET /health and GET /readiness are
// served unauthenticated.
func New(cfg *config.Config) (http.Handler, error) {
	backends := make(map[string]*backend, len(cfg.Models))
	for name, m := range cfg.Models {
		b, err := newBackend(m)
		if err != nil {
			return nil, fmt.Errorf("models.%s: %w", name, err)
		}

		backends[name] = b
	}

	tokens := make([][]byte, len(cfg.AuthTokens))
	for i, t := range cfg.AuthTokens {
		tokens[i] = []byte(t)
	}

	// Shared, so both endpoints reporting the catalog agree on it.
	listed := cfg.Listed()

	mux := http.NewServeMux()
	registerModels(mux, listed)
	proxy := proxyHandler(backends, cfg.MaxBodyBytes, newSlots(cfg.MaxBufferedRequests))
	mux.Handle(routePrefix+"{model}/{path...}", proxy)
	mux.Handle("/", proxy)

	// Health and readiness sit outside the auth middleware: probes and
	// downstream load balancers must be able to check the proxy without a token.
	root := http.NewServeMux()
	registerHealth(root, len(listed))
	registerReadiness(root, backends)
	root.Handle("/", authMiddleware(tokens, mux))

	return root, nil
}

// backend is a resolved model with the proxy and limits serving it.
type backend struct {
	up      *upstream.Upstream
	headers http.Header
	// host overrides the outgoing Host when set, since Go carries Host
	// outside the header map.
	host   string
	health string
	// slots bounds the active proxied requests, nil means unlimited.
	slots chan struct{}
	proxy *httputil.ReverseProxy
}

func newBackend(m config.Model) (*backend, error) {
	up, err := upstream.Parse(m.URL)
	if err != nil {
		return nil, err
	}

	headers := make(http.Header, len(m.Headers))
	for k, v := range m.Headers {
		headers.Set(k, v)
	}

	b := &backend{
		up:      up,
		headers: headers,
		host:    headers.Get("Host"),
		health:  m.Health,
		slots:   newSlots(m.MaxConcurrentRequests),
	}
	headers.Del("Host")

	b.proxy = &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			// ReverseProxy drops unparsable queries, forward them verbatim instead.
			r.Out.URL.RawQuery = r.In.URL.RawQuery
			r.SetXForwarded()
			b.rewrite(r)
		},
		Transport:    up.Transport,
		ErrorHandler: proxyError,
	}

	return b, nil
}

// rewrite addresses r.Out to the backend, shared by proxied requests and
// readiness probes so both reach the same target: the path joins onto the
// base URL, the configured Host replaces the incoming one and the configured
// headers are injected.
func (b *backend) rewrite(r *httputil.ProxyRequest) {
	r.SetURL(b.up.URL)
	r.Out.Host = cmp.Or(b.host, r.In.Host)

	for k, v := range b.headers {
		r.Out.Header[k] = v
	}
}

// routePrefix starts path-routed requests, chosen so it cannot collide with
// OpenAI paths such as GET /v1/models/{model}.
const routePrefix = "/route/"

// bodyTimeout bounds reading a body buffered for its JSON "model" field,
// so a slow client cannot hold a buffering slot for long.
const bodyTimeout = time.Minute

// newSlots returns a semaphore of n slots, nil for unlimited.
func newSlots(n uint) chan struct{} {
	if n == 0 {
		return nil
	}

	return make(chan struct{}, n)
}

// acquire takes a slot and returns its release, safe to call more than once,
// or rejects the request with 503 and reports false once all are taken.
func acquire(w http.ResponseWriter, slots chan struct{}) (func(), bool) {
	if slots == nil {
		return func() {}, true
	}

	select {
	case slots <- struct{}{}:
		return sync.OnceFunc(func() { <-slots }), true
	default:
		http.Error(w, "too many concurrent requests", http.StatusServiceUnavailable)
		return nil, false
	}
}

// proxyHandler forwards each request to the backend named by its
// /route/{model} path prefix, which is stripped and the body streamed,
// or else by its JSON "model" field, for which the body is buffered in one
// of the `buffered` slots until the transport can no longer resend it.
// The per-model concurrency limit applies only once the backend is resolved,
// so a saturated model never blocks requests to another.
func proxyHandler(backends map[string]*backend, maxBytes int64, buffered chan struct{}) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if maxBytes > 0 {
			if req.ContentLength > maxBytes {
				bodyTooLarge(w)
				return
			}

			req.Body = http.MaxBytesReader(w, req.Body, maxBytes)
		}

		name := req.PathValue("model")
		if name == "" {
			release, ok := acquire(w, buffered)
			if !ok {
				return
			}

			defer release()

			if req, name, ok = bodyModel(w, req, release); !ok {
				return
			}
		} else {
			// Cut the escaped path, so escapes such as %2F in the remainder survive.
			_, rest, _ := strings.Cut(strings.TrimPrefix(req.URL.EscapedPath(), routePrefix), "/")
			req.URL.RawPath = "/" + rest
			req.URL.Path = "/" + req.PathValue("path")
		}

		b, ok := backends[name]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", name), http.StatusNotFound)
			return
		}

		release, ok := acquire(w, b.slots)
		if !ok {
			return
		}

		defer release()

		b.proxy.ServeHTTP(w, req)
	}
}

// bodyModel buffers the body to read its JSON "model" field and returns the
// request carrying it as a replayBody, which calls release once the transport
// can no longer resend it, or writes an error response and reports false.
//
// Full buffering validates the entire JSON body before forwarding.
func bodyModel(w http.ResponseWriter, req *http.Request, release func()) (*http.Request, string, bool) {
	body, err := readBody(w, req)
	if err != nil {
		switch _, tooLarge := errors.AsType[*http.MaxBytesError](err); {
		case tooLarge:
			bodyTooLarge(w)
		case errors.Is(err, os.ErrDeadlineExceeded):
			http.Error(w, "request body timeout", http.StatusRequestTimeout)
		default:
			http.Error(w, "failed to read request body", http.StatusBadRequest)
		}

		return nil, "", false
	}

	var request struct {
		Model *string `json:"model"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		http.Error(w, "invalid JSON request body", http.StatusBadRequest)
		return nil, "", false
	}

	if request.Model == nil {
		http.Error(w, "missing model", http.StatusBadRequest)
		return nil, "", false
	}

	rb := &replayBody{body: body, release: release, replayable: replayable(req)}
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
		WroteRequest:         rb.wrote,
		GotFirstResponseByte: rb.gotResponse,
	}))
	req.Body, _ = rb.open()
	req.GetBody = rb.open
	req.ContentLength = int64(len(body))

	// Only a chunked body carries the trailers, read along with the body.
	if len(req.Trailer) > 0 {
		req.ContentLength = -1
	}

	return req, *request.Model, true
}

// replayable mirrors the rule by which http.Transport resends a request with
// a rewindable body after writing it.
func replayable(req *http.Request) bool {
	switch req.Method {
	case http.MethodGet, http.MethodHead, http.MethodOptions, http.MethodTrace:
		return true
	}

	_, key := req.Header["Idempotency-Key"]
	_, xKey := req.Header["X-Idempotency-Key"]

	return key || xKey
}

// readBody reads the whole request body within bodyTimeout, growing the buffer
// as data arrives rather than by the declared length, so a stalled client
// holds neither a buffering slot for long nor memory it never sends.
func readBody(w http.ResponseWriter, req *http.Request) ([]byte, error) {
	rc := http.NewResponseController(w)
	// Fails only for writers without deadlines, such as test recorders.
	_ = rc.SetReadDeadline(time.Now().Add(bodyTimeout))
	body, err := io.ReadAll(req.Body)
	// Cleared, since expiring once the body was read would cancel the request.
	_ = rc.SetReadDeadline(time.Time{})

	return body, err
}

// replayBody holds a buffered request body as long as the transport may
// resend it. It hands out readers of the buffer, which the transport sends
// along with the headers and opens afresh to retry on a stale backend
// connection. Once no retry is possible, it drops the buffer and releases its
// slot, so a long response keeps neither.
type replayBody struct {
	mu      sync.Mutex
	body    []byte
	release func()
	// Whether the transport resends a written request until its response
	// starts, and the state of the current attempt.
	replayable, written, failed, responded bool
}

var errBodySent = errors.New("buffered request body already sent")

func (b *replayBody) open() (io.ReadCloser, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.body == nil {
		return nil, errBodySent
	}

	b.written, b.failed = false, false

	return &replayReader{b: b}, nil
}

// wrote is the WroteRequest hook.
func (b *replayBody) wrote(info httptrace.WroteRequestInfo) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.written, b.failed = true, info.Err != nil
	b.settle()
}

// gotResponse is the GotFirstResponseByte hook.
func (b *replayBody) gotResponse() {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.responded = true
	b.settle()
}

// settle releases the buffer and its slot, with b.mu held, once the transport
// can no longer resend the body: after a response to the written request, or
// after a successful write of a request it never resends. A dropped buffer
// marks it settled, so it releases once.
func (b *replayBody) settle() {
	if b.body == nil || !b.written || !b.responded && (b.failed || b.replayable) {
		return
	}

	b.body = nil
	b.release()
}

// replayReader reads the buffer of b under its lock, so dropping the buffer
// never races with a reader of an earlier attempt, which fails instead.
type replayReader struct {
	b   *replayBody
	off int
}

func (r *replayReader) Read(p []byte) (int, error) {
	r.b.mu.Lock()
	defer r.b.mu.Unlock()

	switch {
	case r.b.body == nil:
		return 0, errBodySent
	case r.off >= len(r.b.body):
		return 0, io.EOF
	}

	n := copy(p, r.b.body[r.off:])
	r.off += n

	return n, nil
}

func (*replayReader) Close() error { return nil }

// bodyTooLarge reports a request body exceeding the size limit.
func bodyTooLarge(w http.ResponseWriter) {
	http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
}

// proxyError maps a streamed body exceeding the size limit to 413, and every
// other upstream failure to 502 like the default ReverseProxy handler.
func proxyError(w http.ResponseWriter, _ *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)
		return
	}

	log.Printf("http: proxy error: %v", err)
	w.WriteHeader(http.StatusBadGateway)
}

// authMiddleware gates next with the configured bearer tokens and strips the
// client Authorization header before it reaches any backend. With no tokens
// configured it is a no-op and the header is forwarded verbatim.
func authMiddleware(tokens [][]byte, next http.Handler) http.Handler {
	if len(tokens) == 0 {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !checkBearer(req.Header.Get("Authorization"), tokens) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		req.Header.Del("Authorization")
		next.ServeHTTP(w, req)
	})
}

// checkBearer reports whether header carries a "Bearer <token>" matching any
// of the configured tokens. The scheme is case-insensitive (RFC 9110, 11.1).
// Comparison is constant-time to avoid leaking token contents via timing.
func checkBearer(header string, tokens [][]byte) bool {
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
