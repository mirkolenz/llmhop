package main

import (
	"net"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/config"
)

func listenLocal(t *testing.T) net.Listener {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() { _ = ln.Close() })

	return ln
}

// Passed sockets serve the listener of their name, whose port or socket
// they must have, or the defaults.
func TestBind(t *testing.T) {
	metrics, web, extra := listenLocal(t), listenLocal(t), listenLocal(t)

	lns, err := bind(
		map[string]config.Listener{"metrics": {Metrics: true}, "web": {Host: "127.0.0.1", Port: uint16(web.Addr().(*net.TCPAddr).Port)}, "api": {Socket: filepath.Join(t.TempDir(), "api.sock")}},
		map[string][]net.Listener{"metrics": {metrics}, "web": {web}, "extra": {extra}},
	)
	if err != nil {
		t.Fatal(err)
	}

	for ln := range lns {
		t.Cleanup(func() { _ = ln.Close() })
	}

	names := slices.Sorted(func(yield func(string) bool) {
		for _, name := range lns {
			yield(name)
		}
	})

	if !slices.Equal(names, []string{"api", "extra", "metrics", "web"}) || lns[metrics] != "metrics" || lns[web] != "web" || lns[extra] != "extra" {
		t.Errorf("got %v", lns)
	}

	misnamed := listenLocal(t)
	cases := []struct {
		name   string
		listen map[string]config.Listener
		passed map[string][]net.Listener
	}{
		{"not passed", map[string]config.Listener{"ssh": {}}, nil},
		{"other address passed", map[string]config.Listener{"ssh": {Host: "127.0.0.1", Port: 1}}, map[string][]net.Listener{"ssh": {listenLocal(t)}}},
		{"passed under another name", map[string]config.Listener{"ssh": {Host: "127.0.0.1", Port: misnamed.Addr().(*net.TCPAddr).AddrPort().Port()}}, map[string][]net.Listener{"unknown": {misnamed}}},
	}

	for _, c := range cases {
		if _, err := bind(c.listen, c.passed); err == nil || !strings.Contains(err.Error(), "listen.ssh") {
			t.Errorf("%s: got error %v", c.name, err)
		}
	}
}
