package router

import "net/http"

// health is the payload of the liveness endpoint. `models` lets a downstream
// probe assert that the proxy came up with the catalog it expects, not just
// that the process is listening. It counts what GET /v1/models advertises.
type health struct {
	Status string `json:"status"`
	Models int    `json:"models"`
}

// registerHealth wires GET /health. The catalog is immutable after startup, so
// the response is built once and reused.
func registerHealth(mux *http.ServeMux, models int) {
	status := health{Status: "ok", Models: models}

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, status)
	})
}
