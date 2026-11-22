package config

import (
	"maps"
	"os"
	"path/filepath"
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
		"listen": [":8080", "[::1]:9090", "unix:///run/llmhop.sock"],
		"authTokens": {"a": "${env:LLMHOP_CFG_TOKEN}", "b": "plain-token"},
		"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_KEY}", "X-Static": "unchanged"}}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	if len(cfg.Listen) != 3 || cfg.MaxBodyBytes != DefaultMaxBodyBytes || cfg.MaxBufferedBytes != DefaultMaxBufferedBytes {
		t.Errorf("got listen %q and limits %d and %d, want defaults", cfg.Listen, cfg.MaxBodyBytes, cfg.MaxBufferedBytes)
	}

	if !maps.Equal(cfg.AuthTokens, map[string]string{"a": "from-env", "b": "plain-token"}) {
		t.Errorf("AuthTokens = %#v", cfg.AuthTokens)
	}

	if h := cfg.Models["m"].Headers; h["Authorization"] != "Bearer sk-123" || h["X-Static"] != "unchanged" {
		t.Errorf("Headers = %#v", h)
	}
}

func TestLoadAuthTokenCredentials(t *testing.T) {
	dir := t.TempDir()
	for name, token := range map[string]string{"llmhop.token.a": "secret-a\n", "other": "unrelated"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(token), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("CREDENTIALS_DIRECTORY", dir)

	cfg, err := Load(writeConfig(t, `{
		"authTokens": {"b": "plain-token"},
		"authTokenCredentials": "llmhop.token.*",
		"models": {"m": {"urls": ["http://x"]}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	if !maps.Equal(cfg.AuthTokens, map[string]string{"a": "secret-a", "b": "plain-token"}) {
		t.Errorf("AuthTokens = %#v", cfg.AuthTokens)
	}
}

// Loading without expansion backs `llmhop check`, which validates configs in
// environments where the referenced secrets do not exist.
func TestLoadKeepsSecretReferences(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")

	cfg, err := Load(writeConfig(t, `{"authTokens": {"t": "${env:LLMHOP_CFG_MISSING}"}, "models": {"m": {"urls": ["http://x"]}}}`), false)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.AuthTokens["t"] != "${env:LLMHOP_CFG_MISSING}" {
		t.Fatalf("AuthTokens = %#v, want the reference verbatim", cfg.AuthTokens)
	}

	if _, err := Load(writeConfig(t, `{"authTokens": {"t": "${nope:x}"}, "models": {"m": {"urls": ["http://x"]}}}`), false); err == nil {
		t.Fatal("accepted malformed secret reference")
	}
}

func TestLoadErrors(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")
	t.Setenv("LLMHOP_CFG_BAD_HEADER", "first\nsecond")

	cases := []struct{ name, body, wantErr string }{
		{"requires models", `{"listen": [":8080"]}`, "no models"},
		{"unknown field", `{"maxBodyByes": 4096, "models": {"m": {"urls": ["http://x"]}}}`, "unknown object member name"},
		{"trailing JSON", `{"models": {"m": {"urls": ["http://x"]}}} {}`, "after top-level value"},
		{"out of range port", `{"listen": [":65536"], "models": {"m": {"urls": ["http://x"]}}}`, "listen"},
		{"missing port", `{"listen": ["localhost"], "models": {"m": {"urls": ["http://x"]}}}`, "listen"},
		{"relative socket", `{"listen": ["unix://run/x.sock"], "models": {"m": {"urls": ["http://x"]}}}`, "listen"},
		{"inner glob", `{"authTokenCredentials": "llmhop.token.**", "models": {"m": {"urls": ["http://x"]}}}`, "single *"},
		{"empty token name", `{"authTokens": {"": "x"}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"invalid token name", `{"authTokens": {"a\u0001": "x"}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"trailing slash model", `{"models": {"org/": {"urls": ["http://x"]}}}`, "models.org/"},
		{"empty model segment", `{"models": {"a//b": {"urls": ["http://x"]}}}`, "models.a//b"},
		{"negative buffering limit", `{"maxBufferedBytes": -1, "models": {"m": {"urls": ["http://x"]}}}`, "maxBufferedBytes"},
		{"empty auth token", `{"authTokens": {"t": ""}, "models": {"m": {"urls": ["http://x"]}}}`, "empty or invalid token"},
		{"duplicate header ignoring case", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "one", "authorization": "two"}}}}`, "duplicate header"},
		{"invalid header name", `{"models": {"m": {"urls": ["http://x"], "headers": {"Bad Header": "value"}}}}`, "invalid header name"},
		{"invalid header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "first\nsecond"}}}}`, "invalid header value"},
		{"invalid expanded header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "${env:LLMHOP_CFG_BAD_HEADER}"}}}}`, "invalid header value"},
		{"auth token expansion", `{"authTokens": {"t": "${env:LLMHOP_CFG_MISSING}"}, "models": {"m": {"urls": ["http://x"]}}}`, "authTokens.t"},
		{"no urls", `{"models": {"m": {"urls": []}}}`, "urls"},
		{"unknown model field", `{"models": {"m": {"urls": ["http://x"], "ulrs": []}}}`, "unknown object member name"},
		{"shared token", `{"authTokens": {"a": "x", "b": "x"}, "models": {"m": {"urls": ["http://x"]}}}`, "a and b share a token"},
		{"too many ranks", `{"models": {"m": {"urls": ["http://x"], "dataParallelSize": 100000}}}`, "dataParallelSize"},
		{"url without scheme", `{"models": {"m": {"urls": ["127.0.0.1:8000"]}}}`, "models.m.urls"},
		{"inner wildcard", `{"models": {"a*b": {"urls": ["http://x"]}}}`, "models.a*b"},
		{"wildcard alias", `{"models": {"m": {"urls": ["http://x"], "aliases": {"n*": {}}}}}`, "aliases"},
		{"alias of another model", `{"models": {"m": {"urls": ["http://x"], "aliases": {"n": {}}}, "n": {"urls": ["http://x"]}}}`, "already a model"},
		{"invalid affinity header", `{"affinity": ["header:Bad Header"], "models": {"m": {"urls": ["http://x"]}}}`, "affinity"},
		{"unknown affinity source", `{"affinity": ["session"], "models": {"m": {"urls": ["http://x"]}}}`, "affinity"},
		{"trusted socket without auth", `{"trustedSockets": {"ssh": "/run/ssh.sock"}, "models": {"m": {"urls": ["http://x"]}}}`, "require authTokens"},
		{"relative trusted socket", `{"authTokens": {"t": "x"}, "trustedSockets": {"ssh": "ssh.sock"}, "models": {"m": {"urls": ["http://x"]}}}`, "absolute socket path"},
		{"unclean trusted socket", `{"authTokens": {"t": "x"}, "trustedSockets": {"ssh": "/run//ssh.sock"}, "models": {"m": {"urls": ["http://x"]}}}`, "absolute socket path"},
		{"unlistened trusted socket", `{"listen": [":8080"], "authTokens": {"t": "x"}, "trustedSockets": {"ssh": "/run/ssh.sock"}, "models": {"m": {"urls": ["http://x"]}}}`, "not in listen"},
		{"trusted socket named like a token", `{"authTokens": {"t": "x"}, "trustedSockets": {"t": "/run/ssh.sock"}, "models": {"m": {"urls": ["http://x"]}}}`, "also names an auth token"},
		{"cors without auth", `{"corsOrigins": ["*"], "models": {"m": {"urls": ["http://x"]}}}`, "require authTokens"},
		{"cors origin with path", `{"authTokens": {"t": "x"}, "corsOrigins": ["https://x/"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"cors wildcard among origins", `{"authTokens": {"t": "x"}, "corsOrigins": ["*", "https://x"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"model header expansion", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_MISSING}"}}}}`, "models.m.headers.Authorization"},
	}

	for _, c := range cases {
		if _, err := Load(writeConfig(t, c.body), true); err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: got error %v, want %q", c.name, err, c.wantErr)
		}
	}
}
