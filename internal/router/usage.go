package router

import (
	"bufio"
	"bytes"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"io"
	"net/http"
)

// usageBody holds the union of the usage members of every known API:
// OpenAI, the Responses API, transcriptions, Anthropic, SGLang and
// llama.cpp. Decoding skips every other member token by token, so it holds
// no more than a token at once.
type usageBody struct {
	Usage    *usageFields `json:"usage"`
	Choices  []struct{}   `json:"choices"`
	Response struct {
		Usage usageFields `json:"usage"`
	} `json:"response"`
	Message struct {
		Usage usageFields `json:"usage"`
	} `json:"message"`
	MetaInfo        usageFields `json:"meta_info"`
	TokensEvaluated int64       `json:"tokens_evaluated"`
	TokensPredicted int64       `json:"tokens_predicted"`
	// Index is the result it belongs to, as in the batches of SGLang.
	Index int64 `json:"index"`
}

type usageFields struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	InputTokens      int64 `json:"input_tokens"`
	OutputTokens     int64 `json:"output_tokens"`
	// The cache tokens of Anthropic count as input.
	CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
}

func (u usageFields) tokens() tokens {
	return tokens{
		max(u.PromptTokens, u.InputTokens+u.CacheCreationInputTokens+u.CacheReadInputTokens),
		max(u.CompletionTokens, u.OutputTokens),
	}
}

// tokens returns the highest counts any member of b reports.
func (b usageBody) tokens() tokens {
	t := tokens{b.TokensEvaluated, b.TokensPredicted}

	for _, u := range []usageFields{b.Response.Usage, b.Message.Usage, b.MetaInfo} {
		t = t.max(u.tokens())
	}

	if b.Usage != nil {
		t = t.max(b.Usage.tokens())
	}

	return t
}

// tokens are the input and output tokens of a response.
type tokens struct {
	input, output int64
}

func (t tokens) total() int64 {
	return t.input + t.output
}

func (t tokens) max(o tokens) tokens {
	return tokens{max(t.input, o.input), max(t.output, o.output)}
}

// usage keeps the highest counts of each result of a response, which are
// its latest ones, since every API reports cumulative counts.
type usage map[int64]tokens

// parse reads the usage of a JSON object of a response, or of each object
// of an array by its position, and reports whether the object is a bare
// usage chunk.
func (u usage) parse(dec *jsontext.Decoder) (bool, error) {
	if dec.PeekKind() == '[' {
		var bodies []usageBody
		err := json.UnmarshalDecode(dec, &bodies)

		for i, b := range bodies {
			u[int64(i)] = u[int64(i)].max(b.tokens())
		}

		return false, err
	}

	var b usageBody
	err := json.UnmarshalDecode(dec, &b)
	u[b.Index] = u[b.Index].max(b.tokens())

	return b.Usage != nil && len(b.Choices) == 0, err
}

// newDecoder decodes the JSON of r leniently, so that invalid UTF-8 or a
// duplicate member before the usage never hides it.
func newDecoder(r io.Reader) *jsontext.Decoder {
	return jsontext.NewDecoder(r, jsontext.AllowInvalidUTF8(true), jsontext.AllowDuplicateNames(true))
}

// sum returns the counts of all results.
func (u usage) sum() tokens {
	var t tokens

	for _, r := range u {
		t.input += r.input
		t.output += r.output
	}

	return t
}

// readUsage reads the usage of a JSON body or of the events of a stream as
// it passes, into the entry of its request once the body is closed.
func readUsage(resp *http.Response) {
	e := entryOf(resp.Request)
	m := meter{ReadCloser: resp.Body, entry: e, usage: make(usage)}

	switch mediaType(resp) {
	case "text/event-stream":
		resp.Body = newEventReader(m)
	case "application/json":
		resp.Body = newJSONReader(m)
	}
}

// meter is a response body whose usage it sets into the entry of its
// request once closed.
type meter struct {
	io.ReadCloser
	entry *entry
	usage usage
}

func (m *meter) Close() error {
	m.entry.usage = m.usage.sum()

	return m.ReadCloser.Close()
}

// jsonReader passes a JSON body unchanged and tees it through a pipe into a
// decoder. The decoder reads every write in full, so a write waits only for
// the handoff, and once it stops, the pipe fails every later write at once.
type jsonReader struct {
	meter
	pipe *io.PipeWriter
	done chan struct{}
}

func newJSONReader(m meter) *jsonReader {
	pr, pw := io.Pipe()
	r := &jsonReader{meter: m, pipe: pw, done: make(chan struct{})}

	go func() {
		_, _ = r.usage.parse(newDecoder(pr))
		_ = pr.Close()
		close(r.done)
	}()

	return r
}

func (r *jsonReader) Read(p []byte) (int, error) {
	n, err := r.meter.Read(p)
	if n > 0 {
		// Fails only once the decoder stopped, which needs no more.
		_, _ = r.pipe.Write(p[:n])
	}

	return n, err
}

// Close ends the decoder at the end of the body read so far.
func (r *jsonReader) Close() error {
	_ = r.pipe.Close()
	<-r.done

	return r.meter.Close()
}

// eventReader passes a stream event by event, reading the usage of each and
// dropping the usage event that only llmhop asked for. It reuses its buffers
// and decoder from one event to the next.
type eventReader struct {
	meter
	r *bufio.Reader
	// event and data are those of the latest event.
	event, data []byte
	src         bytes.Reader
	dec         *jsontext.Decoder
	pending     []byte
	err         error
}

func newEventReader(m meter) *eventReader {
	b := &eventReader{meter: m}
	b.r = bufio.NewReader(&b.meter)
	b.dec = newDecoder(&b.src)

	return b
}

func (b *eventReader) Read(p []byte) (int, error) {
	for len(b.pending) == 0 && b.err == nil {
		b.pending, b.err = b.next()
	}

	if len(b.pending) == 0 {
		return 0, b.err
	}

	n := copy(p, b.pending)
	b.pending = b.pending[n:]

	return n, nil
}

// next reads the next event up to its blank line and returns it, or nothing
// if it is dropped. The event is valid until the next call.
func (b *eventReader) next() ([]byte, error) {
	b.event, b.data = b.event[:0], b.data[:0]

	for {
		start := len(b.event)

		var err error
		b.event, err = appendLine(b.event, b.r)
		line := bytes.TrimRight(b.event[start:], "\r\n")

		if value, ok := bytes.CutPrefix(line, []byte("data:")); ok {
			if len(b.data) > 0 {
				b.data = append(b.data, '\n')
			}

			b.data = append(b.data, bytes.TrimPrefix(value, []byte(" "))...)
		}

		if err != nil || len(line) == 0 {
			b.src.Reset(b.data)
			b.dec.Reset(&b.src)

			if bare, invalid := b.usage.parse(b.dec); invalid == nil && bare && b.entry.stripUsage {
				return nil, err
			}

			return b.event, err
		}
	}
}

// appendLine appends the next line of r to buf, however long.
func appendLine(buf []byte, r *bufio.Reader) ([]byte, error) {
	for {
		chunk, err := r.ReadSlice('\n')
		buf = append(buf, chunk...)

		if !errors.Is(err, bufio.ErrBufferFull) {
			return buf, err
		}
	}
}
