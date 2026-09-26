package systemd

import (
	"fmt"
	"net"
	"os"
	"strconv"
)

// Listeners returns the sockets systemd passed through socket activation, or
// none outside it, so the unit's `.socket` units decide addresses, owners and
// modes.
func Listeners() ([]net.Listener, error) {
	if os.Getenv("LISTEN_PID") != strconv.Itoa(os.Getpid()) {
		return nil, nil
	}

	n, err := strconv.Atoi(os.Getenv("LISTEN_FDS"))
	if err != nil {
		return nil, fmt.Errorf("LISTEN_FDS: %w", err)
	}

	if n < 0 {
		return nil, fmt.Errorf("LISTEN_FDS must not be negative")
	}

	var listeners []net.Listener

	for i := range n {
		// Numbered from SD_LISTEN_FDS_START. FileListener duplicates the
		// descriptor, so the original is closed right away.
		f := os.NewFile(uintptr(3+i), "listener")
		ln, err := net.FileListener(f)
		_ = f.Close()

		if err != nil {
			for _, listener := range listeners {
				_ = listener.Close()
			}

			return nil, fmt.Errorf("socket %d: %w", i, err)
		}

		listeners = append(listeners, ln)
	}

	return listeners, nil
}
