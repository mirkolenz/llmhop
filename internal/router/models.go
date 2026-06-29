package router

import (
	"fmt"
	"maps"
	"net/http"
	"slices"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
)

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

// registerModels wires the read-only OpenAI models API onto mux, serving the
// list and retrieve endpoints directly from the configured models. The catalog
// is immutable after startup, so both responses are built once and reused.
func registerModels(mux *http.ServeMux, cfg *config.Config) {
	// created is stamped once at startup, mirroring how single-model backends
	// report their model's availability time.
	created := time.Now().Unix()

	names := slices.Sorted(maps.Keys(cfg.Models))
	models := make([]model, len(names))
	byName := make(map[string]model, len(names))
	for i, name := range names {
		m := model{ID: name, Object: "model", Created: created, OwnedBy: "llmhop"}
		models[i] = m
		byName[name] = m
	}

	mux.HandleFunc("GET /v1/models", list(models))
	mux.HandleFunc("GET /v1/models/{model}", retrieve(byName))
}

// list serves GET /v1/models, returning every configured model:
//
// https://developers.openai.com/api/reference/resources/models/methods/list
func list(models []model) http.HandlerFunc {
	envelope := modelList{Object: "list", Data: models}
	return func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, envelope)
	}
}

// retrieve serves GET /v1/models/{model}, returning a single configured model
// or 404 when it is unknown:
//
// https://developers.openai.com/api/reference/resources/models/methods/retrieve
func retrieve(byName map[string]model) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("model")
		m, ok := byName[name]
		if !ok {
			http.Error(w, fmt.Sprintf("unknown model %q", name), http.StatusNotFound)
			return
		}
		writeJSON(w, m)
	}
}
