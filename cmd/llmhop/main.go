package main

import (
	"flag"
	"log"
	"net/http"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
)

func main() {
	configPath := flag.String("config", "config.json", "path to JSON config file")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	handler, err := router.New(cfg)
	if err != nil {
		log.Fatalf("router: %v", err)
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s with %d model(s)", cfg.Listen, len(cfg.Models))
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
