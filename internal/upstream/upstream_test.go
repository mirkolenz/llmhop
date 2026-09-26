package upstream

import (
	"io"
	"net"
	"net/http"
	"path/filepath"
	"testing"
)

func TestParse(t *testing.T) {
	for _, raw := range []string{"http://127.0.0.1:8000", "https://api.openai.com/v1", "unix:///run/x.sock"} {
		if _, err := Parse(raw); err != nil {
			t.Errorf("%s: %v", raw, err)
		}
	}

	for _, raw := range []string{"127.0.0.1:8000", "http:///path", "http://user:pass@example.com", "http://example.com/path#fragment", "unix://host/x.sock", "unix://relative.sock", "ftp://x"} {
		if _, err := Parse(raw); err == nil {
			t.Errorf("%s: expected error", raw)
		}
	}
}

func TestUnixTransport(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "http.sock")

	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}

	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, r.URL.Path)
	})}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })

	up, err := Parse("unix://" + socket)
	if err != nil {
		t.Fatal(err)
	}

	client := &http.Client{Transport: up.Transport}

	resp, err := client.Get(up.URL.JoinPath("/health").String())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, _ := io.ReadAll(resp.Body)
	if got := string(body); got != "/health" {
		t.Fatalf("got %q, want /health", got)
	}
}
