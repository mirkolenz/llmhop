package systemd

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// listenNotify stands in for the manager's notification socket.
func listenNotify(t *testing.T) *net.UnixConn {
	t.Helper()

	path := filepath.Join(t.TempDir(), "notify.sock")

	conn, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() { conn.Close() })
	t.Setenv("NOTIFY_SOCKET", path)

	return conn
}

func readNotify(t *testing.T, conn *net.UnixConn) string {
	t.Helper()

	buf := make([]byte, 32)

	n, err := conn.Read(buf)
	if err != nil {
		t.Fatal(err)
	}

	return string(buf[:n])
}

func TestReadyWithoutSocket(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", "")

	if err := Ready(); err != nil {
		t.Fatalf("expected no-op outside systemd, got %v", err)
	}
}

func TestReady(t *testing.T) {
	conn := listenNotify(t)

	if err := Ready(); err != nil {
		t.Fatal(err)
	}

	if got := readNotify(t, conn); got != "READY=1" {
		t.Fatalf("got %q, want READY=1", got)
	}
}

// The 5xx a loading model server returns must read as "not yet" rather than as
// a failure, so readiness is reported only once the endpoint answers 200.
func TestReadyWhenHealthy(t *testing.T) {
	conn := listenNotify(t)

	var calls atomic.Int64

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)

			return
		}

		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := ReadyWhenHealthy(srv.URL, time.Millisecond); err != nil {
		t.Fatal(err)
	}

	if got := readNotify(t, conn); got != "READY=1" {
		t.Fatalf("got %q, want READY=1", got)
	}

	if got := calls.Load(); got != 3 {
		t.Errorf("probed %d times, want 3", got)
	}
}

func TestReadyWhenHealthyReturnsNotifyError(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", filepath.Join(t.TempDir(), "missing.sock"))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := ReadyWhenHealthy(srv.URL, time.Millisecond); err == nil {
		t.Fatal("expected notification error")
	}
}

func TestExitCode(t *testing.T) {
	if got := ExitCode(nil); got != 0 {
		t.Errorf("clean exit: got %d, want 0", got)
	}

	if got := ExitCode(exec.Command("false").Run()); got != 1 {
		t.Errorf("failed exit: got %d, want 1", got)
	}

	// SIGINT is what the units' KillSignal delivers, so its mapping decides
	// whether a drained shutdown looks like a failure.
	if got := ExitCode(exec.Command("sh", "-c", "kill -INT $$").Run()); got != 130 {
		t.Errorf("signalled exit: got %d, want 130", got)
	}
}
