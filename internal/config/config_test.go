package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
		"listen": {"default": {"port": 8080}, "ssh": {"socket": "/run/llmhop.sock"}, "metrics": {"metrics": true}},
		"defaults": {"models": ["m"], "maxConcurrentRequests": 2, "requestsPerMinute": 30},
		"policies": {"research": {"models": ["*"], "weight": 8, "maxConcurrentRequests": 16}},
		"clients": {
			"a": {"key": "${env:LLMHOP_CFG_TOKEN}", "policy": "research", "maxConcurrentRequests": 0},
			"b": {"key": "plain-token"},
			"ssh": {"listener": "ssh"}
		},
		"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_KEY}", "X-Static": "unchanged"}}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	if len(cfg.Listen) != 3 || !cfg.Listen["metrics"].Metrics || cfg.MaxBodyBytes != DefaultMaxBodyBytes || cfg.MaxBufferedBytes != DefaultMaxBufferedBytes {
		t.Errorf("got listen %v and limits %d and %d, want defaults", cfg.Listen, cfg.MaxBodyBytes, cfg.MaxBufferedBytes)
	}

	if a, b := cfg.Clients["a"], cfg.Clients["b"]; a.Key != "from-env" || b.Key != "plain-token" {
		t.Errorf("Clients = %#v", cfg.Clients)
	}

	// The client lifts the limit of its policy, which replaces the models of the defaults.
	a := cfg.EffectivePolicy(cfg.Clients["a"])
	if *a.MaxConcurrentRequests != 0 || *a.RequestsPerMinute != 30 || *a.Weight != 8 || len(a.Models) != 1 || a.Models[0] != "*" {
		t.Errorf("effective policy of a = %+v", a)
	}

	if b := cfg.EffectivePolicy(cfg.Clients["b"]); *b.MaxConcurrentRequests != 2 || b.Weight != nil {
		t.Errorf("effective policy of b = %+v", b)
	}

	if h := cfg.Models["m"].Headers; h["Authorization"] != "Bearer sk-123" || h["X-Static"] != "unchanged" {
		t.Errorf("Headers = %#v", h)
	}
}

func TestLoadClientCredentials(t *testing.T) {
	dir := t.TempDir()
	creds := map[string]string{
		"llmhop.api-key.a": "secret-a\n",
		"llmhop.api-key.b": `{"key": "secret-b", "policy": "guest", "expiresAt": "2027-06-01T00:00:00Z"}`,
		"llmhop.api-key.d": "secret-d",
		"other":            "unrelated",
	}

	for name, value := range creds {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	t.Setenv("CREDENTIALS_DIRECTORY", dir)

	cfg, err := Load(writeConfig(t, `{
		"policies": {"guest": {}},
		"clients": {"d": {"key": "${cred:llmhop.api-key.d}", "policy": "guest"}},
		"clientCredentials": true,
		"models": {"m": {"urls": ["http://x"]}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	want := map[string]Client{
		"a": {Key: "secret-a"},
		"b": {Key: "secret-b", PolicyName: "guest", ExpiresAt: time.Date(2027, 6, 1, 0, 0, 0, 0, time.UTC)},
		"d": {Key: "secret-d", PolicyName: "guest"},
	}

	if len(cfg.Clients) != len(want) {
		t.Fatalf("Clients = %#v", cfg.Clients)
	}

	for name, w := range want {
		got := cfg.Clients[name]
		if got.Key != w.Key || got.PolicyName != w.PolicyName || !got.ExpiresAt.Equal(w.ExpiresAt) {
			t.Errorf("Clients[%s] = %#v, want %#v", name, got, w)
		}
	}
}

// A credential holding more than rotates with its key, or a policy the
// config lost, is skipped, so that the config still starts.
func TestInvalidCredentialsSkipped(t *testing.T) {
	dir := t.TempDir()
	creds := map[string]string{
		"llmhop.api-key.a": `{"key": "x", "maxTokens": 4}`,
		"llmhop.api-key.b": `{"key": "y", "policy": "gone"}`,
		"llmhop.api-key.c": "z",
	}

	for name, value := range creds {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	t.Setenv("CREDENTIALS_DIRECTORY", dir)

	cfg, err := Load(writeConfig(t, `{"clientCredentials": true, "models": {"m": {"urls": ["http://x"]}}}`), true)
	if err != nil || len(cfg.Clients) != 1 || cfg.Clients["c"].Key != "z" {
		t.Fatalf("got %v, %v", cfg, err)
	}
}

// Loading without expansion backs `llmhop check`, which validates configs in
// environments where the referenced secrets do not exist.
func TestLoadKeepsSecretReferences(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")

	cfg, err := Load(writeConfig(t, `{"clients": {"t": {"key": "${env:LLMHOP_CFG_MISSING}"}}, "models": {"m": {"urls": ["http://x"]}}}`), false)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Clients["t"].Key != "${env:LLMHOP_CFG_MISSING}" {
		t.Fatalf("Clients = %#v, want the reference verbatim", cfg.Clients)
	}

	if _, err := Load(writeConfig(t, `{"clients": {"t": {"key": "${nope:x}"}}, "models": {"m": {"urls": ["http://x"]}}}`), false); err == nil {
		t.Fatal("accepted malformed secret reference")
	}
}

func TestLoadErrors(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")
	t.Setenv("LLMHOP_CFG_BAD_HEADER", "first\nsecond")

	cases := []struct{ name, body, wantErr string }{
		{"requires models", `{"listen": {"default": {"port": 8080}}}`, "no models"},
		{"unknown field", `{"maxBodyByes": 4096, "models": {"m": {"urls": ["http://x"]}}}`, "unknown object member name"},
		{"trailing JSON", `{"models": {"m": {"urls": ["http://x"]}}} {}`, "after top-level value"},
		{"out of range port", `{"listen": {"a": {"port": 65536}}, "models": {"m": {"urls": ["http://x"]}}}`, "listen"},
		{"host without port", `{"listen": {"a": {"host": "localhost"}}, "models": {"m": {"urls": ["http://x"]}}}`, "listen.a.host"},
		{"host name", `{"listen": {"a": {"host": "localhost", "port": 80}}, "models": {"m": {"urls": ["http://x"]}}}`, "listen.a.host"},
		{"socket and port", `{"listen": {"a": {"socket": "/x.sock", "port": 80}}, "models": {"m": {"urls": ["http://x"]}}}`, "listen.a.socket"},
		{"relative socket", `{"listen": {"a": {"socket": "run/x.sock"}}, "models": {"m": {"urls": ["http://x"]}}}`, "listen.a.socket"},
		{"empty client name", `{"clients": {"": {"key": "x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"empty policy name", `{"policies": {"": {}}, "models": {"m": {"urls": ["http://x"]}}}`, "empty policy name"},
		{"empty listener name", `{"listen": {"": {"port": 80}}, "models": {"m": {"urls": ["http://x"]}}}`, "empty listener name"},
		{"invalid client name", `{"clients": {"a\u0001": {"key": "x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"trailing slash model", `{"models": {"org/": {"urls": ["http://x"]}}}`, "models.org/"},
		{"empty model segment", `{"models": {"a//b": {"urls": ["http://x"]}}}`, "models.a//b"},
		{"negative buffering limit", `{"maxBufferedBytes": -1, "models": {"m": {"urls": ["http://x"]}}}`, "maxBufferedBytes"},
		{"neither key nor listener", `{"clients": {"t": {}}, "models": {"m": {"urls": ["http://x"]}}}`, "exactly one of key or listener"},
		{"key and listener", `{"listen": {"ssh": {}}, "clients": {"t": {"key": "x", "listener": "ssh"}}, "models": {"m": {"urls": ["http://x"]}}}`, "exactly one of key or listener"},
		{"unknown policy", `{"clients": {"t": {"key": "x", "policy": "nope"}}, "models": {"m": {"urls": ["http://x"]}}}`, "unknown policy"},
		{"invalid model pattern", `{"policies": {"p": {"models": ["a*b"]}}, "models": {"m": {"urls": ["http://x"]}}}`, "policies.p.models"},
		{"duplicate header ignoring case", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "one", "authorization": "two"}}}}`, "duplicate header"},
		{"invalid header name", `{"models": {"m": {"urls": ["http://x"], "headers": {"Bad Header": "value"}}}}`, "invalid header name"},
		{"invalid header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "first\nsecond"}}}}`, "invalid header value"},
		{"invalid expanded header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "${env:LLMHOP_CFG_BAD_HEADER}"}}}}`, "invalid header value"},
		{"key expansion", `{"clients": {"t": {"key": "${env:LLMHOP_CFG_MISSING}"}}, "models": {"m": {"urls": ["http://x"]}}}`, "clients.t.key"},
		{"no urls", `{"models": {"m": {"urls": []}}}`, "urls"},
		{"unknown model field", `{"models": {"m": {"urls": ["http://x"], "ulrs": []}}}`, "unknown object member name"},
		{"shared key", `{"clients": {"a": {"key": "x"}, "b": {"key": "x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "a and b share a key"},
		{"too many ranks", `{"models": {"m": {"urls": ["http://x"], "dataParallelSize": 100000}}}`, "dataParallelSize"},
		{"no ranks", `{"models": {"m": {"urls": ["http://x"], "dataParallelSize": 0}}}`, "dataParallelSize"},
		{"url without scheme", `{"models": {"m": {"urls": ["127.0.0.1:8000"]}}}`, "models.m.urls"},
		{"inner wildcard", `{"models": {"a*b": {"urls": ["http://x"]}}}`, "models.a*b"},
		{"wildcard alias", `{"models": {"m": {"urls": ["http://x"], "aliases": {"n*": {}}}}}`, "aliases"},
		{"alias of another model", `{"models": {"m": {"urls": ["http://x"], "aliases": {"n": {}}}, "n": {"urls": ["http://x"]}}}`, "already a model"},
		{"invalid affinity header", `{"affinity": [{"header": "Bad Header"}], "models": {"m": {"urls": ["http://x"]}}}`, "affinity.0"},
		{"affinity header and body", `{"affinity": [{"header": "X", "body": ["k"]}], "models": {"m": {"urls": ["http://x"]}}}`, "affinity.0"},
		{"empty affinity body", `{"affinity": [{"body": []}], "models": {"m": {"urls": ["http://x"]}}}`, "affinity.0"},
		{"tcp listener client", `{"listen": {"http": {"port": 8080}}, "clients": {"ssh": {"listener": "http"}}, "models": {"m": {"urls": ["http://x"]}}}`, "no unix socket"},
		{"unknown listener client", `{"clients": {"ssh": {"listener": "ssh"}}, "models": {"m": {"urls": ["http://x"]}}}`, "not in listen"},
		{"shared listener", `{"listen": {"ssh": {}}, "clients": {"a": {"listener": "ssh"}, "b": {"listener": "ssh"}}, "models": {"m": {"urls": ["http://x"]}}}`, "a and b share a listener"},
		{"cors without auth", `{"corsOrigins": ["*"], "models": {"m": {"urls": ["http://x"]}}}`, "require clients"},
		{"cors origin with path", `{"clients": {"t": {"key": "x"}}, "corsOrigins": ["https://x/"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"cors wildcard among origins", `{"clients": {"t": {"key": "x"}}, "corsOrigins": ["*", "https://x"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"model header expansion", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_MISSING}"}}}}`, "models.m.headers.Authorization"},
	}

	for _, c := range cases {
		if _, err := Load(writeConfig(t, c.body), true); err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: got error %v, want %q", c.name, err, c.wantErr)
		}
	}
}
