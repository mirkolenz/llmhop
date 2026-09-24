package main

import (
	"flag"
	"log"
	"net"
	"net/http"
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
	}

	for _, ln := range listeners {
		log.Printf("listening on %s with %d model(s)", ln.Addr(), len(cfg.Models))
	}

	if err := systemd.Ready(); err != nil {
		log.Printf("sd_notify: %v", err)
	}

	errs := make(chan error, len(listeners))

	for _, ln := range listeners {
		go func() { errs <- srv.Serve(ln) }()
	}

	log.Fatal(<-errs)
}
