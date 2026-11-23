package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
)

// hashPlaceholder is HASH_<token> in a test config or credential.
var hashPlaceholder = regexp.MustCompile(`HASH_\w+`)

// withHashes replaces every HASH_<token> in s with the hash of the token.
func withHashes(s string) string {
	return hashPlaceholder.ReplaceAllStringFunc(s, func(m string) string {
		return fmt.Sprintf("%x", apikey.Of(strings.TrimPrefix(m, "HASH_")))
	})
}

// writeConfig writes body with its hashes, see withHashes.
func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, []byte(withHashes(body)), 0o600); err != nil {
		t.Fatal(err)
	}

	return p
}

// writeCredentials writes the credentials of files with their hashes, see
// withHashes, as those of the test.
func writeCredentials(t *testing.T, files map[string]string) {
	t.Helper()
	dir := t.TempDir()

	for name, value := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(withHashes(value)), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	t.Setenv("CREDENTIALS_DIRECTORY", dir)
}

func TestLoad(t *testing.T) {
	t.Setenv("LLMHOP_CFG_KEY", "sk-123")

	cfg, err := Load(writeConfig(t, `{
		"listen": {"default": {"port": 8080}, "ssh": {"socket": "/run/llmhop.sock"}, "metrics": {"metrics": true}},
		"defaults": {"models": ["m"], "maxConcurrentRequests": 2, "requestsPerMinute": 30},
		"policies": {"research": {"models": ["*"], "weight": 8, "maxConcurrentRequests": 16}},
		"clients": {
			"a": {"keyHash": "HASH_a", "policy": "research", "maxConcurrentRequests": 0},
			"b": {"keyHash": "HASH_b"},
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

	if a, b := cfg.Clients["a"], cfg.Clients["b"]; a.KeyHash != apikey.Of("a") || b.KeyHash != apikey.Of("b") {
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
	creds := map[string]string{
		"llmhop.api-key.a": `{"keyHash": "HASH_a"}` + "\n",
		"llmhop.api-key.b": `{"keyHash": "HASH_b", "policy": "guest", "expiresAt": "2027-06-01T00:00:00Z"}`,
		"llmhop.api-key.d": `{"keyHash": "HASH_dc"}`,
		"other":            "unrelated",
	}

	writeCredentials(t, creds)

	cfg, err := Load(writeConfig(t, `{
		"policies": {"guest": {}},
		"clients": {"d": {"keyHash": "HASH_d", "policy": "guest"}},
		"clientCredentials": true,
		"models": {"m": {"urls": ["http://x"]}}
	}`), true)
	if err != nil {
		t.Fatal(err)
	}

	// The declared client wins over its credential.
	want := map[string]Client{
		"a": {KeyHash: apikey.Of("a")},
		"b": {KeyHash: apikey.Of("b"), PolicyName: "guest", ExpiresAt: time.Date(2027, 6, 1, 0, 0, 0, 0, time.UTC)},
		"d": {KeyHash: apikey.Of("d"), PolicyName: "guest"},
	}

	if len(cfg.Clients) != len(want) {
		t.Fatalf("Clients = %#v", cfg.Clients)
	}

	for name, w := range want {
		got := cfg.Clients[name]
		if got.KeyHash != w.KeyHash || got.PolicyName != w.PolicyName || !got.ExpiresAt.Equal(w.ExpiresAt) {
			t.Errorf("Clients[%s] = %#v, want %#v", name, got, w)
		}
	}
}

// A credential holding more than rotates with its key, no key, no JSON object, a
// policy the config lost or a taken key is skipped, so that the config
// still starts.
func TestInvalidCredentialsSkipped(t *testing.T) {
	creds := map[string]string{
		"llmhop.api-key.a": `{"keyHash": "HASH_a", "maxTokens": 4}`,
		"llmhop.api-key.b": `{"keyHash": "HASH_b", "policy": "gone"}`,
		"llmhop.api-key.c": "no json",
		"llmhop.api-key.d": `{"keyHash": "HASH_d"}`,
		"llmhop.api-key.e": `{"keyHash": "HASH_d"}`,
		"llmhop.api-key.f": `{"keyHash": "HASH_x"}`,
		"llmhop.api-key.g": `{"policy": ""}`,
	}

	writeCredentials(t, creds)

	cfg, err := Load(writeConfig(t, `{"clientCredentials": true, "clients": {"x": {"keyHash": "HASH_x"}}, "models": {"m": {"urls": ["http://x"]}}}`), true)
	if err != nil || len(cfg.Clients) != 2 || cfg.Clients["d"].KeyHash != apikey.Of("d") {
		t.Fatalf("got %v, %v", cfg, err)
	}
}

// A missing credentials directory, such as /run/secrets of a container
// without secrets, imports no client but still requires one.
func TestMissingCredentialsDirectory(t *testing.T) {
	t.Setenv("CREDENTIALS_DIRECTORY", filepath.Join(t.TempDir(), "missing"))

	cfg, err := Load(writeConfig(t, `{"clientCredentials": true, "models": {"m": {"urls": ["http://x"]}}}`), true)
	if err != nil || len(cfg.Clients) != 0 || !cfg.RequiresAuth() {
		t.Fatalf("got %v, %v", cfg, err)
	}
}

// Loading without expansion backs `llmhop check`, which validates configs in
// environments where the referenced secrets do not exist.
func TestLoadKeepsSecretReferences(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")

	cfg, err := Load(writeConfig(t, `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Key": "${env:LLMHOP_CFG_MISSING}"}}}}`), false)
	if err != nil {
		t.Fatal(err)
	}

	if h := cfg.Models["m"].Headers["X-Key"]; h != "${env:LLMHOP_CFG_MISSING}" {
		t.Fatalf("header = %q, want the reference verbatim", h)
	}

	if _, err := Load(writeConfig(t, `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Key": "${nope:x}"}}}}`), false); err == nil {
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
		{"empty client name", `{"clients": {"": {"keyHash": "HASH_x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"empty policy name", `{"policies": {"": {}}, "models": {"m": {"urls": ["http://x"]}}}`, "empty policy name"},
		{"empty listener name", `{"listen": {"": {"port": 80}}, "models": {"m": {"urls": ["http://x"]}}}`, "empty listener name"},
		{"invalid client name", `{"clients": {"a\u0001": {"keyHash": "HASH_x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "invalid name"},
		{"trailing slash model", `{"models": {"org/": {"urls": ["http://x"]}}}`, "models.org/"},
		{"empty model segment", `{"models": {"a//b": {"urls": ["http://x"]}}}`, "models.a//b"},
		{"negative buffering limit", `{"maxBufferedBytes": -1, "models": {"m": {"urls": ["http://x"]}}}`, "maxBufferedBytes"},
		{"neither key nor listener", `{"clients": {"t": {}}, "models": {"m": {"urls": ["http://x"]}}}`, "exactly one of keyHash or listener"},
		{"key and listener", `{"listen": {"ssh": {}}, "clients": {"t": {"keyHash": "HASH_x", "listener": "ssh"}}, "models": {"m": {"urls": ["http://x"]}}}`, "exactly one of keyHash or listener"},
		{"unknown policy", `{"clients": {"t": {"keyHash": "HASH_x", "policy": "nope"}}, "models": {"m": {"urls": ["http://x"]}}}`, "unknown policy"},
		{"invalid model pattern", `{"policies": {"p": {"models": ["a*b"]}}, "models": {"m": {"urls": ["http://x"]}}}`, "policies.p.models"},
		{"duplicate header ignoring case", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "one", "authorization": "two"}}}}`, "duplicate header"},
		{"invalid header name", `{"models": {"m": {"urls": ["http://x"], "headers": {"Bad Header": "value"}}}}`, "invalid header name"},
		{"invalid header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "first\nsecond"}}}}`, "invalid header value"},
		{"invalid expanded header value", `{"models": {"m": {"urls": ["http://x"], "headers": {"X-Test": "${env:LLMHOP_CFG_BAD_HEADER}"}}}}`, "invalid header value"},
		{"invalid key hash", `{"clients": {"t": {"keyHash": "x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "/clients/t/keyHash"},
		{"no urls", `{"models": {"m": {"urls": []}}}`, "urls"},
		{"unknown model field", `{"models": {"m": {"urls": ["http://x"], "ulrs": []}}}`, "unknown object member name"},
		{"shared key", `{"clients": {"a": {"keyHash": "HASH_x"}, "b": {"keyHash": "HASH_x"}}, "models": {"m": {"urls": ["http://x"]}}}`, "a and b share a key"},
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
		{"cors origin with path", `{"clients": {"t": {"keyHash": "HASH_x"}}, "corsOrigins": ["https://x/"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"cors wildcard among origins", `{"clients": {"t": {"keyHash": "HASH_x"}}, "corsOrigins": ["*", "https://x"], "models": {"m": {"urls": ["http://x"]}}}`, "corsOrigins"},
		{"model header expansion", `{"models": {"m": {"urls": ["http://x"], "headers": {"Authorization": "Bearer ${env:LLMHOP_CFG_MISSING}"}}}}`, "models.m.headers.Authorization"},
	}

	for _, c := range cases {
		if _, err := Load(writeConfig(t, c.body), true); err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: got error %v, want %q", c.name, err, c.wantErr)
		}
	}
}
