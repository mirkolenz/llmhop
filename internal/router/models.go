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
	Object string           `json:"object"`
	Data   []jsontext.Value `json:"data"`
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

// registerHealth wires GET /llmhop/health. The catalog is immutable after startup, so
// the response is built once and reused.
func registerHealth(mux *http.ServeMux, models int) {
	body := jsonBody(health{Status: "ok", Models: models})

	mux.HandleFunc("GET "+reservedPrefix+"health", func(w http.ResponseWriter, _ *http.Request) {
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

		ids := slices.Collect(maps.Keys(m.Aliases))
		if _, wildcard := config.Pattern(name); !wildcard {
			ids = append(ids, name)
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
// objects that the client may use sorted by name. The catalog is immutable
// after startup, so every object is encoded once and reused.
func registerModels(mux *http.ServeMux, objects map[string]modelObject) {
	names := slices.Sorted(maps.Keys(objects))
	byName := make(map[string][]byte, len(objects))

	for _, name := range names {
		byName[name] = jsonBody(objects[name])
	}

	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, r *http.Request) {
		c := entryOf(r).client
		list := modelList{Object: "list", Data: []jsontext.Value{}}

		for _, name := range names {
			if c.allows(name) {
				list.Data = append(list.Data, byName[name])
			}
		}

		writeJSON(w, http.StatusOK, jsonBody(list))
	})

	mux.HandleFunc("GET /v1/models/{model...}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("model")
		m, ok := byName[name]

		switch {
		case !ok:
			unknownModel(w, name)
		case !entryOf(r).client.allows(name):
			modelNotAllowed(w, name)
		default:
			writeJSON(w, http.StatusOK, m)
		}
	})
}

func unknownModel(w http.ResponseWriter, name string) {
	writeError(w, http.StatusNotFound, "model_not_found", fmt.Sprintf("unknown model %q", name))
}

func modelNotAllowed(w http.ResponseWriter, name string) {
	writeError(w, http.StatusForbidden, "model_not_allowed", fmt.Sprintf("this client may not use the model %q", clip(name)))
}
