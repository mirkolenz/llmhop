package router

import (
	"bufio"
	"bytes"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"io"
	"net/http"
	"slices"

	"github.com/VictoriaMetrics/metrics"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// meteredPaths are the endpoints whose responses report their usage in an
// OpenAI usage object, streamed or not.
var meteredPaths = []string{"/v1/chat/completions", "/v1/completions", "/v1/embeddings"}

// meterable reports whether the response of req may report its usage, by
// its method and path, so only such a body is buffered to tell.
func meterable(req *http.Request) bool {
	return req.Method == http.MethodPost && slices.Contains(meteredPaths, req.URL.Path)
}

// emptyObject stands in for absent stream options.
var emptyObject, _ = parseObject([]byte("{}"))

// meterRequest returns the meter of the tokens of a request of c to m with
// the JSON body obj, setting the members in set that ask the servers of a
// stream for its usage as they report it, or nil if its response would
// report none.
func (s *stats) meterRequest(req *http.Request, obj *object, c *client, m *model, set map[string]jsontext.Value) *tokenMeter {
	if obj == nil || !meterable(req) {
		return nil
	}

	// The transport then negotiates and decodes the encoding itself, so the
	// meter reads the body as the client gets it.
	req.Header.Del("Accept-Encoding")

	labels := func(kv ...string) string {
		return telemetry.Labels(append([]string{telemetry.Client, c.name, telemetry.Model, m.name}, kv...)...)
	}
	series := s.series()
	t := &tokenMeter{
		limiters:   c.limiters,
		prompt:     series.GetOrCreateCounter(telemetry.Tokens + labels(telemetry.Kind, telemetry.Prompt)),
		completion: series.GetOrCreateCounter(telemetry.Tokens + labels(telemetry.Kind, telemetry.Completion)),
		unmetered:  series.GetOrCreateCounter(telemetry.UnmeteredResponses + labels()),
	}

	if !obj.flag("stream") {
		return t
	}

	value, _ := obj.member("stream_options")
	options, err := parseObject(value)

	if err != nil {
		options = emptyObject
	}

	ask := map[string]jsontext.Value{"include_usage": jsontext.Value("true")}

	switch m.streamUsage {
	case config.ContinuousUsage:
		ask["continuous_usage_stats"] = jsontext.Value("true")
	case config.TimingsUsage:
		set["timings_per_token"] = jsontext.Value("true")
	}

	set["stream_options"] = options.patch(ask)
	t.injected = !options.flag("include_usage")

	return t
}

// usage is the OpenAI usage object, whose counts grow over the events of a
// stream.
type usage struct {
	Prompt     int64 `json:"prompt_tokens"`
	Completion int64 `json:"completion_tokens"`
}

// timings are the counts of the tokens of a stream that llama.cpp reports
// in its events, of the prompt from its cache and processed, and generated.
type timings struct {
	Cached    int64 `json:"cache_n"`
	Processed int64 `json:"prompt_n"`
	Predicted int64 `json:"predicted_n"`
}

// tokenMeter charges the tokens that a response reports to its client, as
// its counts grow, and the whole token bucket once it ends without any.
type tokenMeter struct {
	limiters                      *limiters
	prompt, completion, unmetered *metrics.Counter
	// injected is whether llmhop asked for the final usage event of a
	// stream, which the client then does not get.
	injected bool
	charged  usage
	// choices holds the completion tokens of each choice of a stream that
	// reports them apart.
	choices map[int]int64
	// seen is whether any usage was reported, and done whether there is
	// nothing left to charge.
	seen, done bool
}

// wrap meters the body of a successful resp, an event stream by its events
// and else a JSON object by its usage member, unless t is nil.
func (t *tokenMeter) wrap(resp *http.Response) {
	if t == nil {
		return
	}

	// A failure costs nothing.
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		t.done = true

		return
	}

	if mediaType(resp.Header) != "text/event-stream" {
		resp.Body = newObjectBody(resp.Body, t)

		return
	}

	// Dropping an event changes the length.
	resp.Header.Del("Content-Length")
	resp.ContentLength = -1
	resp.Body = &eventBody{ReadCloser: resp.Body, lines: bufio.NewReader(resp.Body), meter: t}
}

// chunk is what an event or a JSON response reports of its usage.
type chunk struct {
	// Choices tells an empty list apart from none.
	Choices *[]struct {
		Index int `json:"index"`
	} `json:"choices"`
	Usage   *usage   `json:"usage"`
	Timings *timings `json:"timings"`
}

// report charges what c counts beyond the usage charged before. The usage of
// an event of one choice counts the completion of that choice alone, as vLLM
// and SGLang report several, until an event without choices reports the sum.
func (t *tokenMeter) report(c chunk) {
	u := c.Usage

	if u == nil && c.Timings != nil {
		u = &usage{c.Timings.Cached + c.Timings.Processed, c.Timings.Predicted}
	}

	if u == nil {
		return
	}

	total := *u

	if c.Choices != nil && len(*c.Choices) == 1 {
		index := (*c.Choices)[0].Index
		ensure(&t.choices)[index] = max(t.choices[index], u.Completion)
		total.Completion = 0

		for _, n := range t.choices {
			total.Completion += n
		}
	}

	prompt, completion := max(0, total.Prompt-t.charged.Prompt), max(0, total.Completion-t.charged.Completion)
	t.seen = true

	// Repeated counts skip the lock of the buckets.
	if prompt+completion == 0 {
		return
	}

	t.charged.Prompt += prompt
	t.charged.Completion += completion

	t.prompt.AddInt64(prompt)
	t.completion.AddInt64(completion)
	t.limiters.charge(prompt + completion)
}

// finish fails closed once the response ends without any usage, taking the
// whole token bucket of its client, unless t is nil.
func (t *tokenMeter) finish() {
	if t == nil || t.done {
		return
	}

	t.done = true

	if !t.seen {
		t.unmetered.Inc()
		t.limiters.forfeit()
	}
}

// event charges the usage that the data of an event reports, its data lines
// joined, and reports whether the client gets the event.
func (t *tokenMeter) event(raw []byte) bool {
	var data [][]byte

	for line := range bytes.Lines(raw) {
		if value, ok := bytes.CutPrefix(bytes.TrimRight(line, "\r\n"), []byte("data:")); ok {
			data = append(data, bytes.TrimPrefix(value, []byte(" ")))
		}
	}

	var c chunk

	if len(data) == 0 || json.Unmarshal(bytes.Join(data, []byte("\n")), &c) != nil {
		return true
	}

	t.report(c)

	// The final usage event has no choices.
	return !t.injected || c.Usage == nil || c.Choices == nil || len(*c.Choices) > 0
}

// eventBody is an event stream whose events its meter reads and filters
// before the client gets them.
type eventBody struct {
	io.ReadCloser
	lines *bufio.Reader
	meter *tokenMeter
	// event is the event being read, and out what remains of those read.
	event, out []byte
	err        error
}

func (b *eventBody) Read(p []byte) (int, error) {
	for len(b.out) == 0 && b.err == nil {
		var line []byte
		line, b.err = b.lines.ReadBytes('\n')
		b.event = append(b.event, line...)

		// A blank line ends an event, and the end of the stream any rest.
		if b.err != nil || len(bytes.TrimRight(line, "\r\n")) == 0 {
			if b.meter.event(b.event) {
				b.out = b.event
			}

			// Reused once out is drained.
			b.event = b.event[:0]
		}
	}

	n := copy(p, b.out)
	b.out = b.out[n:]

	if n > 0 {
		return n, nil
	}

	return 0, b.err
}

func (b *eventBody) Close() error {
	b.meter.finish()

	return b.ReadCloser.Close()
}

// objectBody is a JSON response whose usage member a decoder reads from a
// copy of what the client reads, so the body is never held whole.
type objectBody struct {
	io.ReadCloser
	copy  *io.PipeWriter
	done  chan struct{}
	meter *tokenMeter
}

func newObjectBody(body io.ReadCloser, meter *tokenMeter) *objectBody {
	r, w := io.Pipe()
	b := &objectBody{ReadCloser: body, copy: w, done: make(chan struct{}), meter: meter}

	go func() {
		defer close(b.done)

		var response chunk

		if json.UnmarshalRead(r, &response) == nil {
			meter.report(response)
		}

		// The rest of a body that is no JSON object never blocks the copy.
		_, _ = io.Copy(io.Discard, r)
	}()

	return b
}

func (b *objectBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)

	if n > 0 {
		_, _ = b.copy.Write(p[:n])
	}

	return n, err
}

// Close ends the copy, which reports a body cut short as no JSON, and
// finishes the meter once the decoder is done.
func (b *objectBody) Close() error {
	err := b.ReadCloser.Close()
	_ = b.copy.Close()
	<-b.done
	b.meter.finish()

	return err
}
