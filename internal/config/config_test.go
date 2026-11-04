package config

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoad(t *testing.T) {
	t.Setenv("LLMHOP_CFG_TOKEN", "from-env")
	t.Setenv("LLMHOP_CFG_KEY", "sk-123")

	cfg, err := Load(writeConfig(t, `{
		"authTokens": ["${env:LLMHOP_CFG_TOKEN}", "plain-token"],
		"models": {"m": {"url": "http://x", "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_KEY}", "X-Static": "unchanged"}}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Listen() != ":8080" || cfg.MaxBodyBytes != DefaultMaxBodyBytes || cfg.MaxBufferedBytes != DefaultMaxBufferedBytes {
		t.Errorf("got listen %q and limits %d and %d, want defaults", cfg.Listen(), cfg.MaxBodyBytes, cfg.MaxBufferedBytes)
	}

	if !slices.Equal(cfg.AuthTokens, []string{"from-env", "plain-token"}) {
		t.Errorf("AuthTokens = %#v", cfg.AuthTokens)
	}

	if h := cfg.Models["m"].Headers; h["Authorization"] != "Bearer sk-123" || h["X-Static"] != "unchanged" {
		t.Errorf("Headers = %#v", h)
	}
}

// Loading without expansion backs `llmhop check`, which validates configs in
// environments where the referenced secrets do not exist.
func TestLoadKeepsSecretReferences(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")

	cfg, err := Load(writeConfig(t, `{"authTokens": ["${env:LLMHOP_CFG_MISSING}"], "models": {"m": {"url": "http://x"}}}`), false)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.AuthTokens[0] != "${env:LLMHOP_CFG_MISSING}" {
		t.Fatalf("AuthTokens = %#v, want the reference verbatim", cfg.AuthTokens)
	}

	if _, err := Load(writeConfig(t, `{"authTokens": ["${nope:x}"], "models": {"m": {"url": "http://x"}}}`), false); err == nil {
		t.Fatal("accepted malformed secret reference")
	}
}

func TestLoadErrors(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")
	t.Setenv("LLMHOP_CFG_BAD_HEADER", "first\nsecond")

	cases := []struct{ name, body, wantErr string }{
		{"requires models", `{"port": 8080}`, "no models"},
		{"unknown field", `{"maxBodyByes": 4096, "models": {"m": {"url": "http://x"}}}`, "unknown field"},
		{"trailing JSON", `{"models": {"m": {"url": "http://x"}}} {}`, "multiple JSON values"},
		{"out of range port", `{"port": 65536, "models": {"m": {"url": "http://x"}}}`, "port"},
		{"negative buffering limit", `{"maxBufferedBytes": -1, "models": {"m": {"url": "http://x"}}}`, "maxBufferedBytes"},
		{"negative concurrency limit", `{"models": {"m": {"url": "http://x", "maxConcurrentRequests": -1}}}`, "maxConcurrentRequests"},
		{"empty auth token", `{"authTokens": [""], "models": {"m": {"url": "http://x"}}}`, "empty or invalid token"},
		{"duplicate header ignoring case", `{"models": {"m": {"url": "http://x", "headers": {"Authorization": "one", "authorization": "two"}}}}`, "duplicate header"},
		{"invalid header name", `{"models": {"m": {"url": "http://x", "headers": {"Bad Header": "value"}}}}`, "invalid header name"},
		{"invalid header value", `{"models": {"m": {"url": "http://x", "headers": {"X-Test": "first\nsecond"}}}}`, "invalid header value"},
		{"invalid expanded header value", `{"models": {"m": {"url": "http://x", "headers": {"X-Test": "${env:LLMHOP_CFG_BAD_HEADER}"}}}}`, "invalid header value"},
		{"auth token expansion", `{"authTokens": ["${env:LLMHOP_CFG_MISSING}"], "models": {"m": {"url": "http://x"}}}`, "authTokens[0]"},
		{"model header expansion", `{"models": {"m": {"url": "http://x", "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_MISSING}"}}}}`, "models.m.headers.Authorization"},
	}

	for _, c := range cases {
		if _, err := Load(writeConfig(t, c.body), true); err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: got error %v, want %q", c.name, err, c.wantErr)
		}
	}
}
