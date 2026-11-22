package router

import (
	"context"
	"io"
	"mime"
	"net/http"
	"sync/atomic"
	"time"
)

// mediaType returns the media type of a request or response by its header.
func mediaType(h http.Header) string {
	mediaType, _, _ := mime.ParseMediaType(h.Get("Content-Type"))

	return mediaType
}

// idleBody is a response body whose request it cancels once closed, or once
// an event stream reads nothing for its idle timeout.
type idleBody struct {
	io.ReadCloser
	cancel context.CancelFunc
	idle   time.Duration
	start  time.Time
	// read is when the latest read returned data, since start.
	read  atomic.Int64
	timer atomic.Pointer[time.Timer]
}

func newIdleBody(resp *http.Response, idle time.Duration, cancel context.CancelFunc) *idleBody {
	b := &idleBody{ReadCloser: resp.Body, cancel: cancel, idle: idle, start: time.Now()}

	if mediaType(resp.Header) == "text/event-stream" {
		b.timer.Store(time.AfterFunc(idle, b.expire))
	}

	return b
}

// expire cancels the request once idle, or else arms a timer for the rest.
func (b *idleBody) expire() {
	if left := time.Duration(b.read.Load()) + b.idle - time.Since(b.start); left > 0 {
		b.timer.Store(time.AfterFunc(left, b.expire))

		return
	}

	b.cancel()
}

func (b *idleBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)

	if n > 0 {
		b.read.Store(int64(time.Since(b.start)))
	}

	return n, err
}

func (b *idleBody) Close() error {
	if t := b.timer.Load(); t != nil {
		t.Stop()
	}

	b.cancel()

	return b.ReadCloser.Close()
}
