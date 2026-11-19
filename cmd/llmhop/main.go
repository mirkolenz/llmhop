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
	"slices"
	"sync/atomic"
	"time"

	"github.com/coreos/go-systemd/v22/activation"
	"github.com/coreos/go-systemd/v22/daemon"
	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
)

// version is set at build time through `-ldflags "-X main.version=..."`.
var version string

const usage = `usage:
  llmhop serve <config>    serve the router
  llmhop check <config>    validate the config without serving
  llmhop version           print the version
  llmhop help              print this help
`

func main() {
	// journald stamps every line itself. The standard logger, which
	// net/http writes to, forwards to this handler too.
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && a.Key == slog.TimeKey {
				return slog.Attr{}
			}

			return a
		},
	})))

	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	var err error

	switch name, args := os.Args[1], os.Args[2:]; name {
	case "help", "-h", "--help":
		fmt.Print(usage)
	case "version":
		fmt.Println(buildVersion())
	case "serve":
		err = serve(args)
	case "check":
		err = check(args)
	case "internal":
		err = internal(args)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	if err != nil {
		slog.Error(os.Args[1], "err", err)
		os.Exit(1)
	}
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

// internal runs the commands of the Nix modules, which are not public.
func internal(args []string) error {
	if len(args) == 0 {
		return errors.New("missing command")
	}

	switch args[0] {
	case "hub-prune":
		return hubPrune(args[1:])
	case "wait-healthy":
		return waitHealthy(args[1:])
	}

	return fmt.Errorf("unknown command %q", args[0])
}

// configPath returns the only argument, the path of the config.
func configPath(args []string) (string, error) {
	if len(args) != 1 {
		return "", errors.New("expected exactly one argument: <config>")
	}

	return args[0], nil
}

// check builds the router of the config at the only argument without
// expanding its secrets, the exact same router as serving, so every startup
// error short of binding surfaces.
func check(args []string) error {
	path, err := configPath(args)
	if err == nil {
		_, _, err = load(path, false, &router.Limits{})
	}

	return err
}

// load builds the router of the config at path with limits, expanding its
// secrets unless only checking.
func load(path string, expand bool, limits *router.Limits) (*config.Config, http.Handler, error) {
	cfg, err := config.Load(path, expand)
	if err != nil {
		return nil, nil, fmt.Errorf("config: %w", err)
	}

	rt, err := router.New(cfg, limits)
	if err != nil {
		return nil, nil, fmt.Errorf("router: %w", err)
	}

	return cfg, rt, nil
}

// listeners returns the sockets systemd passes, or else binds the `listen`
// entries of the config. Exactly one of them must be present.
func listeners(cfg *config.Config) ([]net.Listener, error) {
	activated, err := activation.Listeners()
	if err != nil {
		return nil, fmt.Errorf("socket activation: %w", err)
	}

	// Activation leaves nil in place of a descriptor that is no listener.
	if slices.Contains(activated, nil) {
		return nil, errors.New("socket activation: passed a descriptor that is no listening socket")
	}

	switch {
	case len(activated) > 0 && len(cfg.Listen) > 0:
		return nil, errors.New("both listen and socket activation are set")
	case len(activated) > 0:
		return activated, nil
	case len(cfg.Listen) == 0:
		return nil, errors.New("no listeners: set listen or use socket activation")
	}

	var lns []net.Listener

	for _, raw := range cfg.Listen {
		network, address, _ := config.ParseListen(raw)

		if network == "unix" {
			// A stale socket of a previous run would fail the bind.
			if err := os.Remove(address); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return nil, fmt.Errorf("listen %s: %w", raw, err)
			}
		}

		ln, err := net.Listen(network, address)
		if err != nil {
			for _, ln := range lns {
				_ = ln.Close()
			}

			return nil, fmt.Errorf("listen %s: %w", raw, err)
		}

		lns = append(lns, ln)
	}

	return lns, nil
}

// serve serves the router on its listeners until SIGTERM or an interrupt,
// reloading the config on SIGHUP.
func serve(args []string) error {
	path, err := configPath(args)
	if err != nil {
		return err
	}

	current := &swappable{}

	cfg, err := current.load(path)
	if err != nil {
		return err
	}

	lns, err := listeners(cfg)
	if err != nil {
		return err
	}

	srv := &http.Server{
		Handler:           current,
		ReadHeaderTimeout: 10 * time.Second,
		// Closes idle keep-alive connections, which would otherwise pin a
		// goroutine and a file descriptor each indefinitely.
		IdleTimeout: 2 * time.Minute,
	}

	for _, ln := range lns {
		slog.Info("listening", "addr", ln.Addr(), "models", len(cfg.Models))
	}

	ctx, stop := signal.NotifyContext(context.Background(), unix.SIGTERM, os.Interrupt)
	defer stop()

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, unix.SIGHUP)

	if err := notify(daemon.SdNotifyReady); err != nil {
		return fmt.Errorf("sd_notify: %w", err)
	}

	errs := make(chan error, len(lns))

	for _, ln := range lns {
		go func() { errs <- srv.Serve(ln) }()
	}

	for ctx.Err() == nil {
		select {
		case err := <-errs:
			return err
		case <-hup:
			reload(path, current)
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
	// unit's StatusErrno, which llmhopctl checks.
	status, errno := "", unix.Errno(0)

	if cfg, err := current.load(path); err != nil {
		slog.Error("reload, keeping the current config", "err", err)
		status, errno = "Reload failed, keeping the current config", unix.EINVAL
	} else {
		slog.Info("reload", "models", len(cfg.Models), "tokens", len(cfg.AuthTokens))
	}

	if err := notify(fmt.Sprintf("%s\nSTATUS=%s\nERRNO=%d", daemon.SdNotifyReady, status, errno)); err != nil {
		slog.Warn("sd_notify", "err", err)
	}
}

// swappable serves with the latest router, while requests in flight keep
// the one they started on, sharing its limits.
type swappable struct {
	atomic.Pointer[http.Handler]
	limits router.Limits
}

func (s *swappable) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	(*s.Load()).ServeHTTP(w, req)
}

// load swaps in the router of the config at path, sharing the limits with
// the router it replaces, or keeps the current one if it fails.
func (s *swappable) load(path string) (*config.Config, error) {
	cfg, rt, err := load(path, true, &s.limits)
	if err == nil {
		s.Store(&rt)
	}

	return cfg, err
}
