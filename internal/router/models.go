package router

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// health is the payload of the liveness endpoint. `models` lets a downstream
// probe assert that the proxy came up with the catalog it expects, not just
// that the process is listening. It counts what GET /v1/models advertises.
type health struct {
	Status string `json:"status"`
	Models int    `json:"models"`
}

// model mirrors the OpenAI model object returned by the retrieve endpoint:
//
// https://developers.openai.com/api/reference/resources/models/methods/retrieve
type model struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	OwnedBy string `json:"owned_by"`
}

// modelList mirrors the OpenAI list envelope returned by the list endpoint:
//
// https://developers.openai.com/api/reference/resources/models/methods/list
type modelList struct {
	Object string  `json:"object"`
	Data   []model `json:"data"`
}

// jsonBody encodes v once, since every payload served here is immutable
// after startup. The types encode infallibly.
func jsonBody(v any) []byte {
	body, _ := json.Marshal(v)
	return body
}

// writeJSON serves a body built by jsonBody.
func writeJSON(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

// registerHealth wires GET /health. The catalog is immutable after startup, so
// the response is built once and reused.
func registerHealth(mux *http.ServeMux, models int) {
	body := jsonBody(health{Status: "ok", Models: models})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, body)
	})
}

// registerModels wires the read-only OpenAI models API onto mux for the
// catalog names it is given. The catalog is immutable after startup, so both
// responses are built once and reused.
func registerModels(mux *http.ServeMux, names []string) {
	// created is stamped once at startup, mirroring how single-model backends
	// report their model's availability time.
	created := time.Now().Unix()

	models := make([]model, len(names))
	byName := make(map[string][]byte, len(names))
	for i, name := range names {
		m := model{ID: name, Object: "model", Created: created, OwnedBy: "llmhop"}
		models[i] = m
		byName[name] = jsonBody(m)
	}

	list := jsonBody(modelList{Object: "list", Data: models})

	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, list)
	})

	mux.HandleFunc("GET /v1/models/{model}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("model")
		m, ok := byName[name]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", name), http.StatusNotFound)
			return
		}
		writeJSON(w, m)
	})
}
