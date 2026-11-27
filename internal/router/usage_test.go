package router

import (
	"compress/gzip"
	"encoding/json/v2"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/config"
)

// The usage of a response is charged to a client with a token limit, which
// admits only requests that report it, gets no final usage event it did not
// ask for, and is rejected once its bucket is in debt. A response compressed
// for the client or an event of several data lines still reports it.
func TestTokenLimit(t *testing.T) {
	// The first event counts as llama.cpp does, the last as OpenAI does.
	events := "data: {\"choices\":[{\"delta\":{}}],\"timings\":{\"cache_n\":1,\"prompt_n\":2,\"predicted_n\":1}}\n\n" +
		"data: {\"choices\":[],\ndata: \"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n" +
		"data: [DONE]\n\n"

	var options map[string]bool

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Stream        bool            `json:"stream"`
			StreamOptions map[string]bool `json:"stream_options"`
		}

		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)

		if !body.Stream {
			response := io.Writer(w)

			if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
				w.Header().Set("Content-Encoding", "gzip")
				gz := gzip.NewWriter(w)
				defer func() { _ = gz.Close() }()
				response = gz
			}

			_, _ = io.WriteString(response, `{"usage":{"prompt_tokens":3,"completion_tokens":2}}`)

			return
		}

		options = body.StreamOptions
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, events)
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Defaults: config.Policy{TokensPerMinute: new(uint32(10))},
		Models:   map[string]config.Model{"m": {URLs: []string{backend.URL}, StreamUsage: config.ContinuousUsage}},
	})

	if rec := send(t, h, http.MethodPost, "/v1/responses", `{"model":"m"}`, ""); rec.Code != http.StatusForbidden {
		t.Errorf("unmetered path got status %d", rec.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"m"}`))
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "usage") {
		t.Errorf("got status %d and body %q", rec.Code, rec.Body)
	}

	rec = send(t, h, http.MethodPost, "/v1/chat/completions", `{"model":"m","stream":true}`, "")
	if rec.Code != http.StatusOK || strings.Contains(rec.Body.String(), `"choices":[]`) || !strings.Contains(rec.Body.String(), "[DONE]") {
		t.Errorf("got status %d and body %q", rec.Code, rec.Body)
	}

	if !options["include_usage"] || !options["continuous_usage_stats"] {
		t.Errorf("backend got stream options %v", options)
	}

	rec = send(t, h, http.MethodPost, "/v1/chat/completions", `{"model":"m"}`, "")
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("X-Ratelimit-Remaining-Tokens") != "0" {
		t.Errorf("got status %d and headers %v", rec.Code, rec.Header())
	}
}
