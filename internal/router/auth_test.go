package router

import (
	"context"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
)

// A token names the client of its hash, only in the Bearer scheme.
func TestBearer(t *testing.T) {
	a := newAuthenticator(&config.Config{Clients: map[string]config.Client{
		"a": {KeyHash: apikey.Of("llmhop_alpha")},
		"b": {KeyHash: apikey.Of("llmhop_beta")},
	}}, &Limits{})
	cases := []struct {
		header string
		want   string
	}{
		{"Bearer llmhop_beta", "b"},
		{"bearer llmhop_alpha", "a"},
		{"Bearer llmhop_alph", ""},
		{"Basic llmhop_alpha", ""},
		{"llmhop_alpha", ""},
	}

	for _, c := range cases {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set("Authorization", c.header)

		got := ""
		if cl := a.bearerClient(req); cl != nil {
			got = cl.name
		}

		if got != c.want {
			t.Errorf("header %q named %q, want %q", c.header, got, c.want)
		}
	}
}

// Client credentials without any credential lock the gateway instead of
// opening it.
func TestAuthRequiredWithoutTokens(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		ClientCredentials: true,
		Models:            map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	if rec := send(t, h, http.MethodPost, "/", `{"model": "m"}`, "Bearer anything"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("got status %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestClientHeaders(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(requestIDHeader, r.Header.Get(requestIDHeader))
		_, _ = w.Write([]byte(r.Header.Get(clientHeader) + " " + r.Header.Get(requestIDHeader)))
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Clients: map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}},
		Models:  map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
	req.Header.Set("Authorization", "Bearer llmhop_t-secret")
	req.Header.Set(requestIDHeader, "r1")
	req.Header.Set(clientHeader, "mallory")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if ids := rec.Header().Values(requestIDHeader); rec.Body.String() != "alice r1" || len(ids) != 1 || ids[0] != "r1" {
		t.Errorf("backend saw %q, response IDs %q", rec.Body.String(), ids)
	}
}

func TestTrustedSockets(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_, _ = w.Write([]byte(r.Header.Get(clientHeader)))
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{
		Clients:     map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}, "ssh": {Listener: "ssh"}},
		CORSOrigins: []string{"*"},
		Models:      map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	cases := []struct {
		name, listener, host string
		header               http.Header
		want                 int
	}{
		{"client listener", "ssh", "localhost:8080", nil, http.StatusOK},
		{"other listener", "default", "localhost:8080", nil, http.StatusUnauthorized},
		{"rebound host", "ssh", "evil.example:8080", nil, http.StatusForbidden},
		{"cross-site request", "ssh", "localhost:8080", http.Header{"Sec-Fetch-Site": {"cross-site"}}, http.StatusForbidden},
		{"same-origin page", "ssh", "127.0.0.1:8080", http.Header{"Origin": {"http://127.0.0.1:8080"}}, http.StatusOK},
	}

	for _, c := range cases {
		req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
		req = req.WithContext(context.WithValue(WithListener(req.Context(), c.listener), http.LocalAddrContextKey, &net.UnixAddr{Name: "/run/llmhop.sock", Net: "unix"}))
		req.Host = c.host
		maps.Copy(req.Header, c.header)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != c.want || c.want == http.StatusOK && rec.Body.String() != "ssh" {
			t.Errorf("%s: got status %d and body %q", c.name, rec.Code, rec.Body.String())
		}

		// The backend's CORS header never reaches a page.
		if rec.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("%s: got CORS headers %v", c.name, rec.Header())
		}
	}
}

func TestCORS(t *testing.T) {
	backend, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		Clients:     map[string]config.Client{"alice": {KeyHash: apikey.Of("llmhop_t-secret")}},
		CORSOrigins: []string{"https://chat.example"},
		Models:      map[string]config.Model{"m": {URLs: []string{backend.URL}}},
	})

	preflight := http.Header{"Access-Control-Request-Method": {"POST"}, "Access-Control-Request-Headers": {"authorization,content-type"}}
	token := http.Header{"Authorization": {"Bearer llmhop_t-secret"}}

	cases := []struct {
		name, method, origin string
		header               http.Header
		status               int
		allowed              string
	}{
		{"preflight", http.MethodOptions, "https://chat.example", preflight, http.StatusNoContent, "https://chat.example"},
		{"request", http.MethodPost, "https://chat.example", token, http.StatusOK, "https://chat.example"},
		{"request without token", http.MethodPost, "https://chat.example", nil, http.StatusUnauthorized, "https://chat.example"},
		{"preflight of another origin", http.MethodOptions, "https://evil.example", preflight, http.StatusNoContent, ""},
	}

	for _, c := range cases {
		req := httptest.NewRequest(c.method, "/v1/chat/completions", strings.NewReader(`{"model":"m"}`))
		req.Header.Set("Origin", c.origin)
		maps.Copy(req.Header, c.header)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != c.status || rec.Header().Get("Access-Control-Allow-Origin") != c.allowed || rec.Header().Get("Access-Control-Allow-Credentials") != "" {
			t.Errorf("%s: got status %d and headers %v", c.name, rec.Code, rec.Header())
		}
	}
}
