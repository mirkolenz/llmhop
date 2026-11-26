package router

import (
	"bytes"
	"cmp"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"io"
	"maps"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sync/semaphore"
)

// bufferedBody is a request body read in full, charged to the budget of
// buffered bytes until released.
type bufferedBody struct {
	data    []byte
	release func()
}

// buffer reads the body of req within the budget of buffered bytes, or
// writes an error response and returns nil.
func buffer(w http.ResponseWriter, req *http.Request, budget *semaphore.Weighted) *bufferedBody {
	charged := &chargedReader{r: req.Body, budget: budget}

	data, err := readBody(w, charged)
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

	return &bufferedBody{data: data, release: sync.OnceFunc(charged.release)}
}

// forward returns req carrying body as a replayBody, and the function that
// lets go of it and the budget once a response is accepted.
func (b *bufferedBody) forward(req *http.Request, body []byte) (*http.Request, func()) {
	rb := newReplayBody(body, b.release)
	req.Body, _ = rb.open()
	req.GetBody = rb.open
	req.ContentLength = int64(len(body))

	// Only a chunked body carries the trailers, read along with the body.
	if len(req.Trailer) > 0 {
		req.ContentLength = -1
	}

	return req, rb.drop
}

// maxModelField bounds the "model" field of a multipart body.
const maxModelField = 4 << 10

// modelField reads the "model" field of a JSON object body, returned with
// its members, or of a multipart one as uploads such as
// /v1/audio/transcriptions send, or describes why a body lacks one.
//
// Full buffering validates the entire JSON body before forwarding, which
// also rejects a duplicate "model" that a backend might resolve differently.
func modelField(contentType string, body []byte) (string, *object, *apiErrorBody) {
	if mediaType, params, err := mime.ParseMediaType(contentType); err == nil && mediaType == "multipart/form-data" {
		name, invalid := multipartModel(multipart.NewReader(bytes.NewReader(body), params["boundary"]))

		return name, nil, invalid
	}

	obj, err := parseObject(body)
	if err != nil {
		return "", nil, errInvalidJSON
	}

	var name *string
	if value, ok := obj.member("model"); ok && json.Unmarshal(value, &name) != nil {
		return "", nil, errInvalidJSON
	}

	if name == nil {
		return "", nil, errMissingModel
	}

	return *name, obj, nil
}

// object is a JSON object with the spans of its member values.
type object struct {
	data    []byte
	members map[string][2]int
	// end is the offset of its closing brace.
	end int
}

// parseObject reads the members of a JSON object in one pass, which also
// validates it whole and rejects duplicate members. The decoder parses the
// buffer in place.
func parseObject(data []byte) (*object, error) {
	dec := jsontext.NewDecoder(bytes.NewBuffer(data))
	if token, err := dec.ReadToken(); err != nil || token.Kind() != '{' {
		return nil, errNoObject
	}

	o := &object{data: data, members: make(map[string][2]int)}

	for dec.PeekKind() == '"' {
		token, err := dec.ReadToken()
		if err != nil {
			return nil, err
		}

		// Read before the value voids the token.
		name := token.String()

		value, err := dec.ReadValue()
		if err != nil {
			return nil, err
		}

		end := int(dec.InputOffset())
		o.members[name] = [2]int{end - len(value), end}
	}

	if _, err := dec.ReadToken(); err != nil {
		return nil, err
	}

	o.end = int(dec.InputOffset()) - 1

	if _, err := dec.ReadToken(); !errors.Is(err, io.EOF) {
		return nil, errNoObject
	}

	return o, nil
}

var errNoObject = errors.New("not a single JSON object")

// member returns the value of a member, of which a nil object has none.
func (o *object) member(name string) (jsontext.Value, bool) {
	if o == nil {
		return nil, false
	}

	span, ok := o.members[name]

	return o.data[span[0]:span[1]], ok
}

// lookup returns the value at a path of members through nested objects.
func (o *object) lookup(path []string) (jsontext.Value, bool) {
	value, ok := o.member(path[0])

	for _, name := range path[1:] {
		inner, err := parseObject(value)
		if !ok || err != nil {
			return nil, false
		}

		value, ok = inner.member(name)
	}

	return value, ok
}

// text returns the string at a path of members, empty for any other value.
func (o *object) text(path ...string) string {
	var s string
	value, _ := o.lookup(path)
	_ = json.Unmarshal(value, &s)

	return s
}

// patch returns the object with the values of set, replacing those of its
// members and appending the others, in one pass that keeps everything else.
func (o *object) patch(set map[string]jsontext.Value) []byte {
	type splice struct {
		start, end int
		value      []byte
	}

	splices := make([]splice, 0, len(set)+1)
	var added []byte
	size := len(o.data)

	for _, name := range slices.Sorted(maps.Keys(set)) {
		if span, ok := o.members[name]; ok {
			splices = append(splices, splice{span[0], span[1], set[name]})
			size += len(set[name]) - (span[1] - span[0])

			continue
		}

		if len(o.members) > 0 || len(added) > 0 {
			added = append(added, ',')
		}

		added, _ = jsontext.AppendQuote(added, name)
		added = append(append(added, ':'), set[name]...)
	}

	splices = append(splices, splice{o.end, o.end, added})
	slices.SortFunc(splices, func(a, b splice) int { return cmp.Compare(a.start, b.start) })

	out := make([]byte, 0, size+len(added))
	at := 0

	for _, s := range splices {
		out = append(append(out, o.data[at:s.start]...), s.value...)
		at = s.end
	}

	return append(out, o.data[at:]...)
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

// replayBody hands a buffered body to the transport, which resends it to
// the same or another server until a response is accepted. Then drop lets go
// of the buffer and releases its budget, so a response streamed for long
// holds neither.
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
