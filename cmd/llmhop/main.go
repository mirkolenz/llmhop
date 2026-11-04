package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
	"github.com/mirkolenz/llmhop/internal/systemd"
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
	log.SetFlags(0)

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
		_, _, err = load(args, false)
	case "internal":
		err = internal(args)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	if err != nil {
		log.Fatalf("%s: %v", os.Args[1], err)
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

// load builds the router of the config at the only argument, expanding its
// secrets unless only checking. Checking builds the exact same router as
// serving, so every startup error short of binding surfaces.
func load(args []string, expand bool) (*config.Config, http.Handler, error) {
	if len(args) != 1 {
		return nil, nil, errors.New("expected exactly one argument: <config>")
	}

	cfg, err := config.Load(args[0], expand)
	if err != nil {
		return nil, nil, fmt.Errorf("config: %w", err)
	}

	handler, err := router.New(cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("router: %w", err)
	}

	return cfg, handler, nil
}

// listeners returns the sockets systemd passes, or else binds the `listen`
// entries of the config. Exactly one of them must be present.
func listeners(cfg *config.Config) ([]net.Listener, error) {
	activated, err := systemd.Listeners()
	if err != nil {
		return nil, fmt.Errorf("socket activation: %w", err)
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

// serve serves the router on its listeners until SIGTERM or an interrupt.
func serve(args []string) error {
	cfg, handler, err := load(args, true)
	if err != nil {
		return err
	}

	lns, err := listeners(cfg)
	if err != nil {
		return err
	}

	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		// Closes idle keep-alive connections, which would otherwise pin a
		// goroutine and a file descriptor each indefinitely.
		IdleTimeout: 2 * time.Minute,
	}

	for _, ln := range lns {
		log.Printf("listening on %s with %d model(s)", ln.Addr(), len(cfg.Models))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	if err := systemd.Ready(); err != nil {
		return fmt.Errorf("sd_notify: %w", err)
	}

	errs := make(chan error, len(lns))

	for _, ln := range lns {
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
