package systemd

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// Ready tells systemd that the listener is bound and the proxy is servable,
// at startup and once a reload finished.
func Ready() error {
	return notify("READY=1")
}

// Reloading tells a `Type=notify-reload` unit that a reload started, stamped
// with the monotonic clock systemd compares to the time it requested it.
func Reloading() error {
	state := "RELOADING=1"
	if usec := monotonicUsec(); usec != 0 {
		state += fmt.Sprintf("\nMONOTONIC_USEC=%d", usec)
	}

	return notify(state)
}

// notify sends state to the notification socket named by $NOTIFY_SOCKET.
// It is a no-op outside systemd, where the variable is unset.
func notify(state string) error {
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
	defer func() { _ = conn.Close() }()

	if _, err := conn.Write([]byte(state)); err != nil {
		return fmt.Errorf("write to %q: %w", addr, err)
	}

	return nil
}
