package router

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"syscall"
)

// attempt is the routing of one proxied request, which the transport of its
// model may move to another server.
type attempt struct {
	affinity
	target  *target
	outcome outcome
	tried   []*server
	// path is the outgoing URL before a server is joined onto it.
	path url.URL
	// upload is the body streamed from the client, unless nil.
	upload *upload
	// accept lets go of a buffered body once a response is accepted, unless
	// nil.
	accept func()
}

type attemptKey struct{}

// attemptOf returns the attempt of a proxied request.
func attemptOf(req *http.Request) *attempt {
	return req.Context().Value(attemptKey{}).(*attempt)
}

// RoundTrip sends out to the target of its attempt, and lets the response
// of an event stream idle for at most the stream idle timeout.
func (m *model) RoundTrip(out *http.Request) (*http.Response, error) {
	if m.streamIdle == 0 {
		return m.send(out)
	}

	ctx, cancel := context.WithCancel(out.Context())

	resp, err := m.send(out.WithContext(ctx))
	if err != nil {
		cancel()

		return nil, err
	}

	// ReverseProxy writes to the body of a switched protocol.
	if body, ok := resp.Body.(io.ReadWriteCloser); ok && resp.StatusCode == http.StatusSwitchingProtocols {
		resp.Body = upgradedBody{body, cancel}

		return resp, nil
	}

	resp.Body = newIdleBody(resp, m.streamIdle, cancel)

	return resp, nil
}

// upgradedBody is the connection of a switched protocol, whose request it
// cancels once closed.
type upgradedBody struct {
	io.ReadWriteCloser
	cancel context.CancelFunc
}

func (b upgradedBody) Close() error {
	b.cancel()

	return b.ReadWriteCloser.Close()
}

// upload is a body streamed from the client, which records whether reading
// it failed, such as beyond the maximum body size.
type upload struct {
	io.ReadCloser
	failed atomic.Bool
}

func (u *upload) Read(p []byte) (int, error) {
	n, err := u.ReadCloser.Read(p)
	if err != nil && !errors.Is(err, io.EOF) {
		u.failed.Store(true)
	}

	return n, err
}

// send sends out to the target of its attempt and moves a body that can be
// resent on to the next server while servers refuse the connection, reset
// it before responding, or answer 502, 503 or 504.
func (m *model) send(out *http.Request) (*http.Response, error) {
	a := attemptOf(out)

	if a.accept != nil {
		defer a.accept()
	}

	for {
		resp, err := a.target.up.Transport.RoundTrip(out)

		// One the client cancelled or failed to upload says nothing about
		// the server.
		if out.Context().Err() != nil || a.upload != nil && a.upload.failed.Load() {
			return resp, err
		}

		var retry bool
		a.outcome, retry = classify(resp, err)

		if !retry || out.Body != nil && out.GetBody == nil || !m.pick(a) {
			return resp, err
		}

		if resp != nil {
			_ = resp.Body.Close()
		}

		out = out.Clone(out.Context())
		m.address(out, a.path, a.target)

		if out.GetBody != nil {
			if out.Body, err = out.GetBody(); err != nil {
				return nil, err
			}
		}
	}
}

// classify returns what a response or error tells about its server and
// whether the request may move on to another one. A refused dial, a reset
// before responding and 502, 503 and 504 fail the server and are retried,
// and any other error fails it. A 429 and any other 5xx may concern the
// request alone, so they tell nothing.
func classify(resp *http.Response, err error) (outcome, bool) {
	if opErr, ok := errors.AsType[*net.OpError](err); ok && opErr.Op == "dial" {
		return refused, true
	}

	if err != nil {
		return failed, errors.Is(err, syscall.ECONNRESET) || errors.Is(err, io.EOF)
	}

	switch code := resp.StatusCode; {
	case code == http.StatusBadGateway || code == http.StatusServiceUnavailable || code == http.StatusGatewayTimeout:
		return failed, true
	case code == http.StatusTooManyRequests || code >= http.StatusInternalServerError:
		return unknown, false
	}

	return succeeded, false
}

// copyBuffers holds the buffers every proxy copies response bodies with,
// which ReverseProxy would otherwise allocate per response.
var copyBuffers bufferPool

// bufferPool pools buffers of the 32 KiB that ReverseProxy copies with.
type bufferPool struct{ pool sync.Pool }

func (p *bufferPool) Get() []byte {
	if b, ok := p.pool.Get().(*[]byte); ok {
		return *b
	}

	return make([]byte, 32<<10)
}

func (p *bufferPool) Put(b []byte) {
	p.pool.Put(&b)
}
