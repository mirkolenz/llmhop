package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"time"
)

type Model struct {
	URL string `json:"url"`
}

type Config struct {
	Listen string           `json:"listen"`
	Models map[string]Model `json:"models"`
}

func newHandler(cfg *Config) (http.Handler, error) {
	proxies := make(map[string]*httputil.ReverseProxy, len(cfg.Models))
	for name, model := range cfg.Models {
		u, err := url.Parse(model.URL)
		if err != nil {
			return nil, fmt.Errorf("model %q: invalid url %q: %w", name, model.URL, err)
		}
		proxies[name] = httputil.NewSingleHostReverseProxy(u)
	}

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		body, err := io.ReadAll(req.Body)
		if err != nil {
			http.Error(w, "failed to read request body", http.StatusBadRequest)
			return
		}

		var probe struct {
			Model string `json:"model"`
		}
		_ = json.Unmarshal(body, &probe)
		proxy, ok := proxies[probe.Model]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", probe.Model), http.StatusNotFound)
			return
		}

		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		proxy.ServeHTTP(w, req)
	}), nil
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{Listen: ":8080"}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	if len(cfg.Models) == 0 {
		return nil, fmt.Errorf("no models configured")
	}
	return cfg, nil
}

func main() {
	configPath := flag.String("config", "config.json", "path to JSON config file")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	handler, err := newHandler(cfg)
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
