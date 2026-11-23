package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"sync/atomic"
	"time"

	"github.com/alecthomas/kong"
	"github.com/coreos/go-systemd/v22/activation"
	"github.com/coreos/go-systemd/v22/daemon"
	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
)

// version is set at build time through `-ldflags "-X main.version=..."`.
var version string

// Globals are the flags of every command.
type Globals struct {
	Config  string           `help:"Path of the config." default:"/etc/llmhop/config.json" env:"LLMHOP_CONFIG" type:"path"`
	Version kong.VersionFlag `help:"Print the version."`
}

// cli is the command line of llmhop.
type cli struct {
	Globals

	Serve    serveCmd    `cmd:"" help:"Serve the gateway, reloading the config on SIGHUP."`
	Check    checkCmd    `cmd:"" help:"Validate the config without serving or reading secrets."`
	Key      keyCmd      `cmd:"" help:"Manage the client keys of clientCredentials."`
	Top      topCmd      `cmd:"" help:"Show what the models and clients do right now."`
	Usage    usageCmd    `cmd:"" help:"Print the requests and errors of the log on stdin by group."`
	Internal internalCmd `cmd:"" hidden:"" help:"Commands of the NixOS module."`
}

func main() {
	// journald stamps every line itself. The standard logger, which
	// net/http writes to, forwards to this handler too.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				return slog.Attr{}
			}

			return a
		},
	})))

	var c cli

	ctx := kong.Parse(&c,
		kong.Name("llmhop"),
		kong.Description("The model gateway llmhop."),
		kong.Vars{"version": buildVersion()},
		kong.BindToProvider(rootConfig),
		kong.UsageOnError(),
	)
	ctx.FatalIfErrorf(ctx.Run(&c.Globals))
}

// buildVersion is the linked version, else the module version of the build.
func buildVersion() string {
	if version != "" {
		return version
	}

	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" && info.Main.Version != "(devel)" {
		return info.Main.Version
	}

	return "dev"
}

type checkCmd struct{}

// Run builds the router of the config without expanding its secrets, the
// exact same router as serving, so every startup error short of binding
// surfaces.
func (checkCmd) Run(g *Globals) error {
	_, rt, err := load(g.Config, false, &router.Limits{}, nil)
	if err == nil {
		rt.Close()
	}

	return err
}

// load builds the router of the config at path with limits, expanding its
// secrets unless only checking. A config replacing prev must keep its
// listeners bound as they are, since their sockets stay open while their
// names select the client policies.
func load(path string, expand bool, limits *router.Limits, prev *config.Config) (*config.Config, *router.Router, error) {
	cfg, err := config.Load(path, expand)
	if err != nil {
		return nil, nil, fmt.Errorf("config: %w", err)
	}

	if prev != nil && !config.SameBindings(prev.Listen, cfg.Listen) {
		return nil, nil, errors.New("listen: rebinding listeners takes a restart")
	}

	rt, err := router.New(cfg, limits)
	if err != nil {
		return nil, nil, fmt.Errorf("router: %w", err)
	}

	return cfg, rt, nil
}

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

type serveCmd struct{}

// Run serves the router on its listeners until SIGTERM or an interrupt,
// reloading the config on SIGHUP.
func (serveCmd) Run(g *Globals) error {
	current := &swappable{}

	cfg, err := current.load(g.Config)
	if err != nil {
		return err
	}

	lns, err := listeners(cfg)
	if err != nil {
		return err
	}

	srv := &http.Server{
		Handler: current,
		BaseContext: func(ln net.Listener) context.Context {
			return router.WithListener(context.Background(), lns[ln])
		},
		ReadHeaderTimeout: 10 * time.Second,
		// Closes idle keep-alive connections, which would otherwise pin a
		// goroutine and a file descriptor each indefinitely.
		IdleTimeout: 2 * time.Minute,
	}

	for ln, name := range lns {
		slog.Info("listening", "listener", name, "addr", ln.Addr().String(), "models", len(cfg.Models))
	}

	ctx, stop := signal.NotifyContext(context.Background(), unix.SIGTERM, os.Interrupt)
	defer stop()

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, unix.SIGHUP)

	if err := notify(daemon.SdNotifyReady); err != nil {
		return fmt.Errorf("sd_notify: %w", err)
	}

	errs := make(chan error, len(lns))

	for ln := range lns {
		go func() { errs <- srv.Serve(ln) }()
	}

	for ctx.Err() == nil {
		select {
		case err := <-errs:
			return err
		case <-hup:
			reload(g.Config, current)
		case <-ctx.Done():
		}
	}

	// Restores default signal handling, so a second signal aborts the drain,
	// and ignores reloads meanwhile.
	stop()
	signal.Stop(hup)
	slog.Info("shutting down, draining in-flight requests")

	// Unbounded on purpose, systemd's TimeoutStopSec caps the drain.
	if err := srv.Shutdown(context.Background()); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}

	return nil
}

// notify sends state to systemd, a no-op outside it.
func notify(state string) error {
	_, err := daemon.SdNotify(false, state)

	return err
}

// reload replaces the router with one of the config at path, keeping the
// current one if it fails, between the RELOADING=1 and READY=1 a
// `Type=notify-reload` unit waits for. Only the listeners take a restart.
func reload(path string, current *swappable) {
	// systemd ignores RELOADING=1 unless stamped no earlier than its request.
	// Reading CLOCK_MONOTONIC cannot fail.
	var now unix.Timespec
	_ = unix.ClockGettime(unix.CLOCK_MONOTONIC, &now)

	if err := notify(fmt.Sprintf("%s\nMONOTONIC_USEC=%d", daemon.SdNotifyReloading, now.Nano()/1_000)); err != nil {
		slog.Warn("sd_notify", "err", err)
	}

	// systemd knows no failed reload, so ERRNO= reports the outcome as the
	// unit's StatusErrno, which `llmhop key` checks.
	status, errno := "", unix.Errno(0)

	if cfg, err := current.load(path); err != nil {
		slog.Error("reload, keeping the current config", "err", err)
		status, errno = "Reload failed, keeping the current config", unix.EINVAL
	} else {
		slog.Info("reload", "models", len(cfg.Models), "clients", len(cfg.Clients))
	}

	if err := notify(fmt.Sprintf("%s\nSTATUS=%s\nERRNO=%d", daemon.SdNotifyReady, status, errno)); err != nil {
		slog.Warn("sd_notify", "err", err)
	}
}

// swappable serves with the latest router, while requests in flight keep
// the one they started on, sharing its limits.
type swappable struct {
	atomic.Pointer[router.Router]
	limits router.Limits
	// cfg is that of the latest router, which only reloads replace.
	cfg *config.Config
}

func (s *swappable) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	s.Load().ServeHTTP(w, req)
}

// load swaps in the router of the config at path, sharing the limits with
// the router it replaces and closing that, or keeps the current one if it
// fails.
func (s *swappable) load(path string) (*config.Config, error) {
	cfg, rt, err := load(path, true, &s.limits, s.cfg)
	if err != nil {
		return nil, err
	}

	rt.Start()

	if old := s.Swap(rt); old != nil {
		old.Close()
	}

	s.cfg = cfg

	return cfg, nil
}
