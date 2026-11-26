package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"time"

	"github.com/coreos/go-systemd/v22/daemon"
	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
)

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
