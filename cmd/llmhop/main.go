package main

import (
	"context"
	"flag"
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

func main() {
	configPath := flag.String("config", "config.json", "path to JSON config file")
	check := flag.Bool("check", false, "validate the config and exit without serving")
	flag.Parse()

	// Checking builds the exact same router as serving, so every startup error
	// short of binding the port surfaces.
	cfg, err := config.Load(*configPath, !*check)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	handler, err := router.New(cfg)
	if err != nil {
		log.Fatalf("router: %v", err)
	}

	if *check {
		return
	}

	listeners, err := systemd.Listeners()
	if err != nil {
		log.Fatalf("socket activation: %v", err)
	}

	if len(listeners) == 0 {
		ln, err := net.Listen("tcp", cfg.Listen())
		if err != nil {
			log.Fatalf("listen: %v", err)
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
		log.Fatalf("sd_notify: %v", err)
	}

	errs := make(chan error, len(listeners))

	for _, ln := range listeners {
		go func() { errs <- srv.Serve(ln) }()
	}

	select {
	case err := <-errs:
		log.Fatal(err)
	case <-ctx.Done():
	}

	// Restores default signal handling, so a second signal aborts the drain.
	stop()
	log.Print("shutting down, draining in-flight requests")

	// Unbounded on purpose, systemd's TimeoutStopSec caps the drain.
	if err := srv.Shutdown(context.Background()); err != nil {
		log.Fatalf("shutdown: %v", err)
	}
}
