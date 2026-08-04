// Package systemd implements the sliver of the sd_notify(3) protocol llmhop
// needs to report readiness to its supervisor.
package systemd

import (
	"fmt"
	"net"
	"os"
	"strings"
)

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
