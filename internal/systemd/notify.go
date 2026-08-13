// Package systemd implements the sliver of systemd's service protocol llmhop
// needs: sd_notify(3) readiness, and the exit status a supervising unit reports
// back to the manager.
package systemd

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// Bound on a single health probe; the unit's `TimeoutStartSec` bounds the wait
// as a whole.
const probeTimeout = 10 * time.Second

// Ready sends READY=1 to the notification socket named by $NOTIFY_SOCKET,
// telling a `Type=notify` unit that the listener is bound and the proxy is
// servable. It is a no-op outside systemd, where the variable is unset.
func Ready() error {
	addr := os.Getenv("NOTIFY_SOCKET")
	if addr == "" {
		return nil
	}

	// A leading `@` selects the abstract namespace, encoded as a leading NUL.
	if name, ok := strings.CutPrefix(addr, "@"); ok {
		addr = "\x00" + name
	}

	conn, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: addr, Net: "unixgram"})
	if err != nil {
		return fmt.Errorf("dial %q: %w", addr, err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("READY=1")); err != nil {
		return fmt.Errorf("write to %q: %w", addr, err)
	}

	return nil
}

// ReadyWhenHealthy polls url until it answers 200, then reports readiness on
// behalf of a server that speaks no sd_notify itself.
func ReadyWhenHealthy(url string, interval time.Duration) error {
	client := &http.Client{Timeout: probeTimeout}
	defer client.CloseIdleConnections()

	for !healthy(client, url) {
		time.Sleep(interval)
	}

	return Ready()
}

// healthy reports whether url answers 200. The body is drained before closing
// so the transport keeps one connection for the whole wait instead of opening
// a fresh one per probe.
func healthy(client *http.Client, url string) bool {
	resp, err := client.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<12))

	return resp.StatusCode == http.StatusOK
}

// ExitCode maps a supervised process's termination onto the supervisor's own
// exit status, so systemd sees the failure the child actually had. A signalled
// death has no exit code of its own, hence the shell's `128 + signal`.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}

	var exitErr *exec.ExitError

	if !errors.As(err, &exitErr) {
		log.Printf("wait: %v", err)

		return 1
	}

	if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}

	return exitErr.ExitCode()
}
