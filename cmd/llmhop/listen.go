package main

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"

	"github.com/coreos/go-systemd/v22/activation"

	"github.com/mirkolenz/llmhop/internal/config"
)

// listeners returns the sockets systemd passes and binds the listeners of
// the config with an address, each by the name of its listener.
func listeners(cfg *config.Config) (map[net.Listener]string, error) {
	activated, err := activatedListeners()
	if err != nil {
		return nil, fmt.Errorf("socket activation: %w", err)
	}

	// Only a unix socket's permissions decide who connects.
	for name, c := range cfg.Clients {
		if c.Listener == "" {
			continue
		}

		for _, ln := range activated[c.Listener] {
			if _, ok := ln.(*net.UnixListener); !ok {
				return nil, fmt.Errorf("clients.%s.listener: systemd passes %s, no unix socket", name, ln.Addr())
			}
		}
	}

	return bind(cfg.Listen, activated)
}

// activatedListeners returns the sockets systemd passes by name, failing on
// one that is no listener, such as a datagram socket.
func activatedListeners() (map[string][]net.Listener, error) {
	lns := make(map[string][]net.Listener)

	for _, f := range activation.Files(true) {
		ln, err := net.FileListener(f)
		_ = f.Close()

		if err != nil {
			return nil, fmt.Errorf("%s: %w", f.Name(), err)
		}

		lns[f.Name()] = append(lns[f.Name()], ln)
	}

	return lns, nil
}

// bind binds the listeners with an address that systemd does not pass,
// beside the passed sockets by name, each of which serves the listener of
// its name if any.
func bind(listen map[string]config.Listener, passed map[string][]net.Listener) (map[net.Listener]string, error) {
	lns := make(map[net.Listener]string)

	for name, socks := range passed {
		_, named := listen[name]

		for _, ln := range socks {
			lns[ln] = name

			// A socket unit without the name of its listener would leave
			// llmhop rebinding its address without its permissions.
			for other, l := range listen {
				if !named && sameAddress(l, ln.Addr()) {
					return nil, fmt.Errorf("listen.%s: systemd passes %s under the name %q", other, ln.Addr(), name)
				}
			}
		}
	}

	for name, l := range listen {
		ln, err := bindListener(l, passed[name])
		if err != nil {
			for ln := range lns {
				_ = ln.Close()
			}

			return nil, fmt.Errorf("listen.%s: %w", name, err)
		}

		if ln != nil {
			lns[ln] = name
		}
	}

	if len(lns) == 0 {
		return nil, errors.New("no listeners: set listen or use socket activation")
	}

	return lns, nil
}

// bindListener binds a listener, or returns nil if systemd passes its
// sockets, which must have its port or socket if it has one.
func bindListener(l config.Listener, passed []net.Listener) (net.Listener, error) {
	network, address := l.Network()

	if network == "" {
		if len(passed) == 0 {
			return nil, errors.New("no port or socket and systemd passes no socket of its name")
		}

		return nil, nil
	}

	for _, ln := range passed {
		if !sameAddress(l, ln.Addr()) {
			return nil, fmt.Errorf("systemd passes %s instead of %s", ln.Addr(), address)
		}
	}

	if len(passed) > 0 {
		return nil, nil
	}

	if network == "unix" {
		// A stale socket of a previous run would fail the bind.
		if err := os.Remove(address); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
	}

	return net.Listen(network, address)
}

// sameAddress reports whether addr has the port or socket of l, where an
// empty or unspecified host is every interface.
func sameAddress(l config.Listener, addr net.Addr) bool {
	switch a := addr.(type) {
	case *net.UnixAddr:
		return l.Socket != "" && a.Name == l.Socket
	case *net.TCPAddr:
		got, host := a.AddrPort(), l.Addr()

		return got.Port() == l.Port && (host == got.Addr().Unmap() || host.IsUnspecified() && got.Addr().IsUnspecified())
	}

	return false
}
