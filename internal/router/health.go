package router

import (
	"net/http"

	"github.com/mirkolenz/llmhop/internal/config"
)

// health is the payload of the liveness endpoint. `models` lets a downstream
// probe assert that the proxy came up with the catalog it expects, not just
// that the process is listening.
type health struct {
	Status string `json:"status"`
	Models int    `json:"models"`
}

// registerHealth wires GET /health. The catalog is immutable after startup, so
// the response is built once and reused.
func registerHealth(mux *http.ServeMux, cfg *config.Config) {
	status := health{Status: "ok", Models: len(cfg.Models)}

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, status)
	})
}
