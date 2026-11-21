// Package router builds the HTTP handler that authenticates incoming
// requests, serves the OpenAI models API from the configured models and
// forwards every other request through a per-model reverse proxy with
// injected headers, selected by the /route/{model} path prefix or the
// "model" field of a JSON or multipart body, and balanced over the servers
// of the model.
package router

import (
	"bytes"
	"cmp"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sync/semaphore"

	"github.com/mirkolenz/llmhop/internal/config"
)

// New returns the handler of cfg, which serves the OpenAI models API from
// the configured models and proxies every other request to the model named
// by its /route/{model} path prefix or else its body, all guarded by the
// auth tokens or trusted sockets. Only GET /health and GET /readiness are
// served unauthenticated and unlogged. It is immutable, so a reload replaces
// it, sharing the limits with the router it replaces.
func New(cfg *config.Config, limits *Limits) (http.Handler, error) {
	rt := &routes{exact: make(map[string]*model), affinity: cfg.Affinity}
	var models []*model

	for name, m := range cfg.Models {
		md, err := newModel(m, limits.semaphore("models."+name, int64(m.MaxConcurrentRequests)))
		if err != nil {
			return nil, fmt.Errorf("models.%s: %w", name, err)
		}

		if prefix, ok := config.Pattern(name); ok {
			rt.patterns = append(rt.patterns, pattern{prefix, md})
		} else {
			rt.exact[name] = md
		}

		for _, alias := range m.Aliases {
			rt.exact[alias] = md
		}

		for _, n := range append([]string{name}, m.Aliases...) {
			rt.segments = max(rt.segments, strings.Count(n, "/")+1)
		}

		models = append(models, md)
	}

	// The longest prefix wins.
	slices.SortFunc(rt.patterns, func(a, b pattern) int { return cmp.Compare(len(b.prefix), len(a.prefix)) })

	objects := catalog(cfg.Models)
	mux := http.NewServeMux()
	registerModels(mux, objects)
	mux.Handle("/", rt.proxyHandler(cfg.MaxBodyBytes, limits.semaphore("maxBufferedBytes", cfg.MaxBufferedBytes)))

	var api http.Handler = mux
	if cfg.RequiresAuth() {
		api = newAuthenticator(cfg).wrap(api)
	}

	// Health and readiness sit outside the auth middleware: probes and
	// downstream load balancers must be able to check the proxy without a token.
	root := http.NewServeMux()
	registerHealth(root, len(objects))
	registerReadiness(root, models)
	root.Handle("/", logRequests(api))

	return root, nil
}

// routes resolves a model name to its model.
type routes struct {
	// exact holds every model name and alias.
	exact map[string]*model
	// patterns holds the wildcards, the longest prefix first.
	patterns []pattern
	// segments is the most path segments of an exact name, which bounds
	// the prefixes of a path that may name a model.
	segments int
	affinity []string
}

type pattern struct {
	prefix string
	model  *model
}

// lookup resolves a model name, else the longest wildcard prefixing it.
func (rt *routes) lookup(name string) *model {
	if m, ok := rt.exact[name]; ok {
		return m
	}

	for _, p := range rt.patterns {
		if strings.HasPrefix(name, p.prefix) {
			return p.model
		}
	}

	return nil
}

// routePrefix starts path-routed requests, chosen so it cannot collide with
// OpenAI paths such as GET /v1/models/{model}.
const routePrefix = "/route/"

// bodyTimeout bounds reading a body buffered for its "model" field,
// so a slow client cannot hold buffered bytes for long.
const bodyTimeout = time.Minute

// proxyHandler forwards each request to the model named by its
// /route/{model} path prefix, which is stripped and the body streamed,
// or else by the "model" field of its body, which is buffered within the
// `buffered` budget until the backend starts its response. The concurrency
// limit applies only once the model is resolved, so a saturated model never
// blocks requests to another.
func (rt *routes) proxyHandler(maxBytes int64, buffered *semaphore.Weighted) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if maxBytes > 0 {
			if req.ContentLength > maxBytes {
				bodyTooLarge(w)

				return
			}

			req.Body = http.MaxBytesReader(w, req.Body, maxBytes)
		}

		var name string
		var m *model
		var body []byte

		if strings.HasPrefix(req.URL.Path, routePrefix) {
			name, m = rt.routeModel(req.URL)
		} else {
			b := bodyModel(w, req, buffered)
			if b == nil {
				return
			}

			defer b.release()

			req, name, body = b.req, b.model, b.body
			m = rt.lookup(name)
		}

		entryOf(req).model = name

		if m == nil {
			unknownModel(w, name)

			return
		}

		// Computed before queueing, so a large body holds no slot meanwhile.
		var aff affinity
		if len(m.targets) > 1 {
			aff = affinityOf(req, rt.affinity, body)
		}

		m.serve(w, req, aff)
	}
}

// routeModel resolves the model of a /route/<model>/<path> URL and strips
// the prefix and model from it. The longest model name wins, and a name with
// `/` may be written raw or with `%2F`. The remainder keeps its escapes. An
// unknown model is reported as its first segment. Wildcards do not apply,
// since they leave the end of the name open.
func (rt *routes) routeModel(u *url.URL) (string, *model) {
	segments := strings.Split(strings.TrimPrefix(u.EscapedPath(), routePrefix), "/")

	for n := min(len(segments), rt.segments); n > 0; n-- {
		name, err := url.PathUnescape(strings.Join(segments[:n], "/"))
		if m, ok := rt.exact[name]; ok && err == nil {
			u.RawPath = "/" + strings.Join(segments[n:], "/")
			u.Path, _ = url.PathUnescape(u.RawPath)

			return name, m
		}
	}

	name, _ := url.PathUnescape(segments[0])

	return name, nil
}

// bufferedRequest is a request whose body was read for its "model" field.
type bufferedRequest struct {
	req   *http.Request
	model string
	body  []byte
	// release drops the body and its budget, which also happens once the
	// backend starts its response.
	release func()
}

// bodyModel buffers the body, charged to buffered, to read its "model"
// field and returns the request carrying it as a replayBody, or writes an
// error response and returns nil.
//
// Full buffering validates the entire JSON body before forwarding, which
// also rejects a duplicate "model" that a backend might resolve differently.
func bodyModel(w http.ResponseWriter, req *http.Request, buffered *semaphore.Weighted) *bufferedRequest {
	charged := &chargedReader{r: req.Body, budget: buffered}

	body, err := readBody(w, charged)
	if err != nil {
		charged.release()

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

		return nil
	}

	name, invalid := modelField(req.Header.Get("Content-Type"), body)
	if invalid != nil {
		charged.release()
		writeError(w, http.StatusBadRequest, invalid.Code, invalid.Message)

		return nil
	}

	rb := newReplayBody(body, charged.release)
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

	return &bufferedRequest{req: req, model: name, body: body, release: rb.drop}
}

// maxModelField bounds the "model" field of a multipart body.
const maxModelField = 4 << 10

// modelField reads the "model" field of a JSON body, or of a multipart one
// as uploads such as /v1/audio/transcriptions send, or describes why a body
// lacks one.
func modelField(contentType string, body []byte) (string, *apiErrorBody) {
	if mediaType, params, err := mime.ParseMediaType(contentType); err == nil && mediaType == "multipart/form-data" {
		return multipartModel(multipart.NewReader(bytes.NewReader(body), params["boundary"]))
	}

	var request struct {
		Model *string `json:"model"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		return "", &apiErrorBody{Code: "invalid_json", Message: "invalid JSON request body"}
	}

	if request.Model == nil {
		return "", errMissingModel
	}

	return *request.Model, nil
}

// multipartModel reads the only "model" field of a form, which the whole
// form must hold exactly once and in full, since the backend reads the
// form itself and must not see another model than the one routed by.
func multipartModel(r *multipart.Reader) (string, *apiErrorBody) {
	var model *string

	for {
		part, err := r.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}

		if err != nil {
			return "", errInvalidMultipart
		}

		if part.FormName() != "model" {
			continue
		}

		value, err := io.ReadAll(io.LimitReader(part, maxModelField+1))
		if err != nil || model != nil || len(value) > maxModelField {
			return "", errInvalidMultipart
		}

		model = new(string(value))
	}

	if model == nil {
		return "", errMissingModel
	}

	return *model, nil
}

var (
	errMissingModel     = &apiErrorBody{Code: "missing_model", Message: "missing model"}
	errInvalidMultipart = &apiErrorBody{Code: "invalid_multipart", Message: "invalid multipart request body or model field"}
)

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

var errBudgetExceeded = errors.New("buffered request bodies exceed their budget")

// chargedReader takes every byte it reads from the budget of buffered bytes,
// which bounds the bodies held at once, so a body is charged only for the
// data that has arrived.
type chargedReader struct {
	r      io.Reader
	budget *semaphore.Weighted
	// n counts the bytes charged so far.
	n int64
}

// release returns the bytes charged so far to the budget.
func (c *chargedReader) release() {
	c.budget.Release(c.n)
}

func (c *chargedReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if !c.budget.TryAcquire(int64(n)) {
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

// proxyError maps a streamed body exceeding the size limit to 413, a backend
// exceeding its response timeout to 504, and every other upstream failure to
// 502 like the default ReverseProxy handler.
func proxyError(w http.ResponseWriter, req *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)

		return
	}

	slog.Error("proxy", "id", req.Header.Get(requestIDHeader), "err", err)

	if netErr, ok := errors.AsType[net.Error](err); ok && netErr.Timeout() {
		writeError(w, http.StatusGatewayTimeout, "backend_timeout", "backend response timeout")

		return
	}

	writeError(w, http.StatusBadGateway, "bad_gateway", "backend unreachable")
}
