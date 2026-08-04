package systemd

import (
	"net"
	"path/filepath"
	"testing"
)

func TestReadyWithoutSocket(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", "")

	if err := Ready(); err != nil {
		t.Fatalf("expected no-op outside systemd, got %v", err)
	}
}

func TestReady(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notify.sock")
	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	t.Setenv("NOTIFY_SOCKET", path)

	if err := Ready(); err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 32)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatal(err)
	}

	if got := string(buf[:n]); got != "READY=1" {
		t.Fatalf("got %q, want READY=1", got)
	}
}
