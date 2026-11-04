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
	"sync/atomic"
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
	proxy := proxyHandler(backends, cfg.MaxBodyBytes, newBudget(cfg.MaxBufferedBytes))
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
// so a slow client cannot hold buffered bytes for long.
const bodyTimeout = time.Minute

// newSlots returns a semaphore of n slots, nil for unlimited.
func newSlots(n uint) chan struct{} {
	if n == 0 {
		return nil
	}

	return make(chan struct{}, n)
}

// acquire takes a slot and returns its release, or rejects the request with
// 429 and reports false once all are taken.
func acquire(w http.ResponseWriter, slots chan struct{}) (func(), bool) {
	if slots == nil {
		return func() {}, true
	}

	select {
	case slots <- struct{}{}:
		return func() { <-slots }, true
	default:
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "too_many_requests", "too many concurrent requests for this model")
		return nil, false
	}
}

// proxyHandler forwards each request to the backend named by its
// /route/{model} path prefix, which is stripped and the body streamed,
// or else by its JSON "model" field, for which the body is buffered within
// the `buffered` budget until the backend starts its response.
// The per-model concurrency limit applies only once the backend is resolved,
// so a saturated model never blocks requests to another.
func proxyHandler(backends map[string]*backend, maxBytes int64, buffered *budget) http.HandlerFunc {
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
			var release func()
			var ok bool
			if req, name, release, ok = bodyModel(w, req, buffered); !ok {
				return
			}

			defer release()
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

// bodyModel buffers the body, charged to buffered, to read its JSON "model"
// field and returns the request carrying it as a replayBody with the release
// of its budget, or writes an error response and reports false.
//
// Full buffering validates the entire JSON body before forwarding.
func bodyModel(w http.ResponseWriter, req *http.Request, buffered *budget) (_ *http.Request, model string, release func(), ok bool) {
	charged := &chargedReader{r: req.Body, budget: buffered}
	defer func() {
		if !ok {
			buffered.give(charged.n)
		}
	}()

	body, err := readBody(w, charged)
	if err != nil {
		switch _, tooLarge := errors.AsType[*http.MaxBytesError](err); {
		case tooLarge:
			bodyTooLarge(w)
		case errors.Is(err, errBudgetExceeded):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusServiceUnavailable, "buffer_budget_exceeded", "request body buffer budget exhausted, retry later")
		case errors.Is(err, os.ErrDeadlineExceeded):
			writeError(w, http.StatusRequestTimeout, "request_body_timeout", "request body timeout")
		default:
			writeError(w, http.StatusBadRequest, "invalid_request_body", "failed to read request body")
		}

		return nil, "", nil, false
	}

	var request struct {
		Model *string `json:"model"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "invalid JSON request body")
		return nil, "", nil, false
	}

	if request.Model == nil {
		writeError(w, http.StatusBadRequest, "missing_model", "missing model")
		return nil, "", nil, false
	}

	rb := newReplayBody(body, func() { buffered.give(charged.n) })
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), &httptrace.ClientTrace{
		GotFirstResponseByte: rb.drop,
	}))
	req.Body, _ = rb.open()
	req.GetBody = rb.open
	req.ContentLength = int64(len(body))

	// Only a chunked body carries the trailers, read along with the body.
	if len(req.Trailer) > 0 {
		req.ContentLength = -1
	}

	return req, *request.Model, rb.drop, true
}

// readBody reads the whole body within bodyTimeout, growing the buffer as
// data arrives rather than by the declared length, so a stalled client holds
// neither a budget nor memory it never sends.
func readBody(w http.ResponseWriter, body io.Reader) ([]byte, error) {
	rc := http.NewResponseController(w)
	// Fails only for writers without deadlines, such as test recorders.
	_ = rc.SetReadDeadline(time.Now().Add(bodyTimeout))
	data, err := io.ReadAll(body)
	// Cleared, since expiring once the body was read would cancel the request.
	_ = rc.SetReadDeadline(time.Time{})

	return data, err
}

// budget bounds the bytes of buffered bodies held at once, so any number of
// small requests buffer in parallel while large ones cannot exhaust memory.
// A nil budget is unlimited.
type budget struct {
	free atomic.Int64
}

func newBudget(n int64) *budget {
	if n == 0 {
		return nil
	}

	b := &budget{}
	b.free.Store(n)

	return b
}

// take reserves n bytes, or reports false if fewer are free.
func (b *budget) take(n int64) bool {
	if b == nil {
		return true
	}

	for {
		free := b.free.Load()
		if free < n {
			return false
		}

		if b.free.CompareAndSwap(free, free-n) {
			return true
		}
	}
}

func (b *budget) give(n int64) {
	if b != nil {
		b.free.Add(n)
	}
}

var errBudgetExceeded = errors.New("buffered request bodies exceed their budget")

// chargedReader takes every byte it reads from the budget, so a body is
// charged only for the data that has arrived.
type chargedReader struct {
	r      io.Reader
	budget *budget
	// n counts the bytes charged so far.
	n int64
}

func (c *chargedReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if !c.budget.take(int64(n)) {
		return 0, errBudgetExceeded
	}

	c.n += int64(n)

	return n, err
}

// replayBody hands a buffered body to the transport, which resends it on a
// fresh connection until the response starts. Then drop lets go of the buffer
// and releases its budget, so a response streamed for long holds neither.
type replayBody struct {
	buf  atomic.Pointer[[]byte]
	drop func()
}

func newReplayBody(body []byte, release func()) *replayBody {
	rb := &replayBody{}
	rb.buf.Store(&body)
	rb.drop = sync.OnceFunc(func() {
		rb.buf.Store(nil)
		release()
	})

	return rb
}

var errBodySent = errors.New("buffered request body already sent")

func (rb *replayBody) open() (io.ReadCloser, error) {
	buf := rb.buf.Load()
	if buf == nil {
		return nil, errBodySent
	}

	return &dropReader{buf: *buf}, nil
}

// dropReader reads a buffer and lets go of it at EOF, so the request, which
// lives as long as its response, does not keep the buffer alive.
type dropReader struct {
	buf []byte
}

func (r *dropReader) Read(p []byte) (int, error) {
	if len(r.buf) == 0 {
		r.buf = nil
		return 0, io.EOF
	}

	n := copy(p, r.buf)
	r.buf = r.buf[n:]

	return n, nil
}

func (*dropReader) Close() error { return nil }

// bodyTooLarge reports a request body exceeding the size limit.
func bodyTooLarge(w http.ResponseWriter) {
	writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body too large")
}

// proxyError maps a streamed body exceeding the size limit to 413, and every
// other upstream failure to 502 like the default ReverseProxy handler.
func proxyError(w http.ResponseWriter, _ *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)
		return
	}

	log.Printf("http: proxy error: %v", err)
	writeError(w, http.StatusBadGateway, "bad_gateway", "backend unreachable")
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
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeError(w, http.StatusUnauthorized, "invalid_api_key", "missing or invalid bearer token")
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
