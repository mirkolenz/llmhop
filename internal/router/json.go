package router

import (
	"encoding/json"
	"net/http"
)

// writeJSON encodes v as a JSON response body. It is the shared response
// helper for every native route llmhop serves itself, so new custom routes
// can reuse it instead of repeating the encoding boilerplate.
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
