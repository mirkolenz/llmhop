package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
	"github.com/mirkolenz/llmhop/internal/systemd"
)

const usage = `usage:
  llmhop serve [-config path]         serve the router
  llmhop check [-config path]         validate the config without serving
  llmhop hub-prune <specification>    prune the hub cache of a worker
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	var err error

	switch name, args := os.Args[1], os.Args[2:]; name {
	case "serve":
		err = serve(args)
	case "check":
		_, _, err = load(name, args, false)
	case "hub-prune":
		err = hubPrune(args)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	if err != nil {
		log.Fatalf("%s: %v", os.Args[1], err)
	}
}

// load builds the router of the config that the `-config` flag in args
// names, expanding its secrets unless only checking. Checking builds the
// exact same router as serving, so every startup error short of binding the
// port surfaces.
func load(name string, args []string, expand bool) (*config.Config, http.Handler, error) {
	flags := flag.NewFlagSet(name, flag.ExitOnError)
	configPath := flags.String("config", "config.json", "path to JSON config file")
	_ = flags.Parse(args)

	cfg, err := config.Load(*configPath, expand)
	if err != nil {
		return nil, nil, fmt.Errorf("config: %w", err)
	}

	handler, err := router.New(cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("router: %w", err)
	}

	return cfg, handler, nil
}

// serve serves the router on the listeners systemd passes, or else on the
// address of its config, until SIGTERM or an interrupt.
func serve(args []string) error {
	cfg, handler, err := load("serve", args, true)
	if err != nil {
		return err
	}

	listeners, err := systemd.Listeners()
	if err != nil {
		return fmt.Errorf("socket activation: %w", err)
	}

	if len(listeners) == 0 {
		ln, err := net.Listen("tcp", cfg.Listen())
		if err != nil {
			return fmt.Errorf("listen: %w", err)
		}

		listeners = []net.Listener{ln}
	}

	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		// Closes idle keep-alive connections, which would otherwise pin a
		// goroutine and a file descriptor each indefinitely.
		IdleTimeout: 2 * time.Minute,
	}

	for _, ln := range listeners {
		log.Printf("listening on %s with %d model(s)", ln.Addr(), len(cfg.Models))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	if err := systemd.Ready(); err != nil {
		return fmt.Errorf("sd_notify: %w", err)
	}

	errs := make(chan error, len(listeners))

	for _, ln := range listeners {
		go func() { errs <- srv.Serve(ln) }()
	}

	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
	}

	// Restores default signal handling, so a second signal aborts the drain.
	stop()
	log.Print("shutting down, draining in-flight requests")

	// Unbounded on purpose, systemd's TimeoutStopSec caps the drain.
	if err := srv.Shutdown(context.Background()); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}

	return nil
}
