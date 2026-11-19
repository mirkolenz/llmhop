package router

import (
	"encoding/json/jsontext"
	"encoding/json/v2"
	"fmt"
	"maps"
	"net/http"
	"slices"

	"github.com/mirkolenz/llmhop/internal/config"
)

// health is the payload of the liveness endpoint. `models` lets a downstream
// probe assert that the proxy came up with the catalog it expects, not just
// that the process is listening. It counts what GET /v1/models advertises.
type health struct {
	Status string `json:"status"`
	Models int    `json:"models"`
}

// modelObject is the OpenAI model object returned by the retrieve endpoint,
// with the configured metadata as further members:
//
// https://developers.openai.com/api/reference/resources/models/methods/retrieve
type modelObject map[string]jsontext.Value

// modelList mirrors the OpenAI list envelope returned by the list endpoint:
//
// https://developers.openai.com/api/reference/resources/models/methods/list
type modelList struct {
	Object string        `json:"object"`
	Data   []modelObject `json:"data"`
}

// jsonBody encodes v, so payloads immutable after startup are encoded once.
// The types encode infallibly, and maps in a stable order.
func jsonBody(v any) []byte {
	body, _ := json.Marshal(v, json.Deterministic(true))

	return body
}

// writeJSON serves a body built by jsonBody with the given status.
func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// registerHealth wires GET /health. The catalog is immutable after startup, so
// the response is built once and reused.
func registerHealth(mux *http.ServeMux, models int) {
	body := jsonBody(health{Status: "ok", Models: models})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, body)
	})
}

// catalog returns the model objects of every listed model and its aliases
// by name. A wildcard names no model, so only its aliases are listed.
func catalog(models map[string]config.Model) map[string]modelObject {
	objects := make(map[string]modelObject, len(models))

	for name, m := range models {
		if m.Unlisted {
			continue
		}

		ids := m.Aliases
		if _, wildcard := config.Pattern(name); !wildcard {
			ids = append([]string{name}, ids...)
		}

		for _, id := range ids {
			// A fixed time keeps the catalog the same over reloads.
			obj := modelObject{"created": jsontext.Value("0"), "owned_by": jsontext.Value(`"llmhop"`)}
			maps.Copy(obj, m.Metadata)
			obj["id"] = jsonBody(id)
			obj["object"] = jsontext.Value(`"model"`)
			objects[id] = obj
		}
	}

	return objects
}

// registerModels wires the read-only OpenAI models API onto mux, listing the
// objects sorted by name. The catalog is immutable after startup, so every
// response is built once and reused.
func registerModels(mux *http.ServeMux, objects map[string]modelObject) {
	byName := make(map[string][]byte, len(objects))
	list := modelList{Object: "list", Data: make([]modelObject, 0, len(objects))}

	for _, name := range slices.Sorted(maps.Keys(objects)) {
		byName[name] = jsonBody(objects[name])
		list.Data = append(list.Data, objects[name])
	}

	listBody := jsonBody(list)

	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, listBody)
	})

	mux.HandleFunc("GET /v1/models/{model...}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("model")
		m, ok := byName[name]
		if !ok {
			unknownModel(w, name)

			return
		}
		writeJSON(w, http.StatusOK, m)
	})
}

func unknownModel(w http.ResponseWriter, name string) {
	writeError(w, http.StatusNotFound, "model_not_found", fmt.Sprintf("unknown model %q", name))
}
