// Package upstream resolves a backend address into the base URL requests are
// sent to and the transport that reaches it, so a backend may listen either on
// TCP or on a unix socket.
package upstream

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
)

// Upstream is a parsed backend address.
type Upstream struct {
	// URL is the base every request is sent to.
	URL *url.URL
	// Transport reaches URL, dialing the socket of a `unix://` address.
	Transport http.RoundTripper
}

// idleConnsPerHost keeps the connections to a backend serving concurrent
// requests open, where the default of 2 would redial all others after each.
const idleConnsPerHost = 64

// sharedTransport reaches every http(s) backend.
var sharedTransport = newTransport()

func newTransport() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.MaxIdleConnsPerHost = idleConnsPerHost

	return t
}

// Parse accepts an absolute http(s) URL or `unix:///<socket path>`. A socket
// address carries no HTTP path, so requests go to the root of the server
// listening on it.
func Parse(raw string) (*Upstream, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}

	// `url.Parse` happily accepts `127.0.0.1:8000` (scheme `127.0.0.1`),
	// which would only surface as a proxy error per request.
	switch u.Scheme {
	case "http", "https":
		if u.User != nil || u.Fragment != "" {
			return nil, errors.New("http(s) backend URL must not contain credentials or a fragment")
		}

		if u.Host != "" {
			return &Upstream{URL: u, Transport: sharedTransport}, nil
		}
	case "unix":
		if u.Host != "" || !path.IsAbs(u.Path) || u.RawQuery != "" || u.Fragment != "" {
			return nil, fmt.Errorf("url %q must be unix:///<absolute socket path>", raw)
		}

		transport := newTransport()
		transport.Proxy = nil

		var dialer net.Dialer

		transport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", u.Path)
		}

		return &Upstream{URL: &url.URL{Scheme: "http", Host: "localhost"}, Transport: transport}, nil
	}

	return nil, fmt.Errorf("url %q must be an absolute http(s) or unix URL", raw)
}
