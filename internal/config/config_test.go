package config

import (
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

func TestLoadMissingFile(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "missing.json"), true); err == nil {
		t.Fatal("expected error for missing file")
	}
}

// Loading without expansion backs `llmhop -check`, which validates configs in
// environments where the referenced secrets do not exist.
func TestLoadKeepsSecretReferences(t *testing.T) {
	_ = os.Unsetenv("LLMHOP_CFG_MISSING")
	path := writeConfig(t, `{
		"authTokens": ["${env:LLMHOP_CFG_MISSING}"],
		"models": {"m": {"url": "http://x"}}
	}`)

	if _, err := Load(path, true); err == nil {
		t.Fatal("expected error for unresolvable reference")
	}

	cfg, err := Load(path, false)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.AuthTokens[0] != "${env:LLMHOP_CFG_MISSING}" {
		t.Fatalf("AuthTokens = %#v, want the reference verbatim", cfg.AuthTokens)
	}

	if _, err := Load(writeConfig(t, `{"authTokens": ["${"], "models": {"m": {"url": "http://x"}}}`), false); err == nil {
		t.Fatal("accepted malformed secret reference")
	}
}

func TestLoad(t *testing.T) {
	const minimal = `{"models": {"m": {"url": "http://x"}}}`

	cases := []struct {
		name    string
		setenv  map[string]string
		body    string
		check   func(t *testing.T, cfg *Config)
		wantErr string
	}{
		{
			name:    "invalid JSON",
			body:    "{not json",
			wantErr: "",
		},
		{
			name:    "requires models",
			body:    `{"port": 8080}`,
			wantErr: "no models",
		},
		{
			name:    "rejects unknown fields",
			body:    `{"maxBodyByes": 4096, "models": {"m": {"url": "http://x"}}}`,
			wantErr: "unknown field",
		},
		{
			name:    "rejects trailing JSON",
			body:    minimal + ` {}`,
			wantErr: "multiple JSON values",
		},
		{
			name:    "rejects out of range port",
			body:    `{"port": 65536, "models": {"m": {"url": "http://x"}}}`,
			wantErr: "port 65536",
		},
		{
			name:    "rejects negative body limit",
			body:    `{"maxBodyBytes": -1, "models": {"m": {"url": "http://x"}}}`,
			wantErr: "maxBodyBytes",
		},
		{
			name:    "rejects negative concurrency limit",
			body:    `{"maxConcurrentRequests": -1, "models": {"m": {"url": "http://x"}}}`,
			wantErr: "maxConcurrentRequests",
		},
		{
			name:    "rejects empty model name",
			body:    `{"models": {"": {"url": "http://x"}}}`,
			wantErr: "model name",
		},
		{
			name:    "rejects empty auth token",
			body:    `{"authTokens": [""], "models": {"m": {"url": "http://x"}}}`,
			wantErr: "empty token",
		},
		{
			name:    "rejects duplicate header names ignoring case",
			body:    `{"models": {"m": {"url": "http://x", "headers": {"Authorization": "one", "authorization": "two"}}}}`,
			wantErr: "duplicate header",
		},
		{
			name:    "rejects invalid header name",
			body:    `{"models": {"m": {"url": "http://x", "headers": {"Bad Header": "value"}}}}`,
			wantErr: "invalid header name",
		},
		{
			name:    "rejects invalid header value",
			body:    `{"models": {"m": {"url": "http://x", "headers": {"X-Test": "first\nsecond"}}}}`,
			wantErr: "invalid header value",
		},
		{
			name:    "rejects invalid expanded header value",
			setenv:  map[string]string{"LLMHOP_CFG_BAD_HEADER": "first\nsecond"},
			body:    `{"models": {"m": {"url": "http://x", "headers": {"X-Test": "${env:LLMHOP_CFG_BAD_HEADER}"}}}}`,
			wantErr: "invalid header value",
		},
		{
			name:    "requires absolute model URLs",
			body:    `{"models": {"m": {"url": "localhost:8000"}}}`,
			wantErr: "absolute http(s) or unix URL",
		},
		{
			name: "defaults applied",
			body: minimal,
			check: func(t *testing.T, cfg *Config) {
				if cfg.Listen() != ":8080" {
					t.Fatalf("Listen() = %q, want :8080", cfg.Listen())
				}
				if cfg.MaxBodyBytes != DefaultMaxBodyBytes {
					t.Fatalf("MaxBodyBytes = %d, want %d", cfg.MaxBodyBytes, DefaultMaxBodyBytes)
				}
				if cfg.MaxConcurrentRequests != DefaultMaxConcurrentRequests {
					t.Fatalf("MaxConcurrentRequests = %d, want %d", cfg.MaxConcurrentRequests, DefaultMaxConcurrentRequests)
				}
			},
		},
		{
			name: "brackets IPv6 literals",
			body: `{"host": "::1", "port": 9000, "models": {"m": {"url": "http://x"}}}`,
			check: func(t *testing.T, cfg *Config) {
				if cfg.Listen() != "[::1]:9000" {
					t.Fatalf("Listen() = %q, want [::1]:9000", cfg.Listen())
				}
			},
		},
		{
			name: "custom limits",
			body: `{"maxBodyBytes": 4096, "maxConcurrentRequests": 4, "models": {"m": {"url": "http://x"}}}`,
			check: func(t *testing.T, cfg *Config) {
				if cfg.MaxBodyBytes != 4096 || cfg.MaxConcurrentRequests != 4 {
					t.Fatalf("got limits %d and %d", cfg.MaxBodyBytes, cfg.MaxConcurrentRequests)
				}
			},
		},
		{
			name: "zero disables limits",
			body: `{"maxBodyBytes": 0, "maxConcurrentRequests": 0, "models": {"m": {"url": "http://x"}}}`,
			check: func(t *testing.T, cfg *Config) {
				if cfg.MaxBodyBytes != 0 || cfg.MaxConcurrentRequests != 0 {
					t.Fatalf("got limits %d and %d", cfg.MaxBodyBytes, cfg.MaxConcurrentRequests)
				}
			},
		},
		{
			name:   "expands auth tokens and model headers",
			setenv: map[string]string{"LLMHOP_CFG_TOKEN": "from-env", "LLMHOP_CFG_KEY": "sk-123"},
			body: `{
				"authTokens": ["${env:LLMHOP_CFG_TOKEN}", "plain-token"],
				"models": {"m": {"url": "http://x", "headers": {
					"Authorization": "Bearer ${env:LLMHOP_CFG_KEY}",
					"X-Static": "unchanged"
				}}}
			}`,
			check: func(t *testing.T, cfg *Config) {
				if cfg.AuthTokens[0] != "from-env" || cfg.AuthTokens[1] != "plain-token" {
					t.Fatalf("AuthTokens = %#v", cfg.AuthTokens)
				}
				h := cfg.Models["m"].Headers
				if h["Authorization"] != "Bearer sk-123" || h["X-Static"] != "unchanged" {
					t.Fatalf("Headers = %#v", h)
				}
			},
		},
		{
			name: "auth token expansion error",
			body: `{
				"authTokens": ["${env:LLMHOP_CFG_MISSING}"],
				"models": {"m": {"url": "http://x"}}
			}`,
			wantErr: "authTokens[0]",
		},
		{
			name: "model header expansion error",
			body: `{
				"models": {"m": {"url": "http://x", "headers": {
					"Authorization": "Bearer ${env:LLMHOP_CFG_MISSING}"
				}}}
			}`,
			wantErr: "models.m.headers.Authorization",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_ = os.Unsetenv("LLMHOP_CFG_MISSING")
			for k, v := range c.setenv {
				t.Setenv(k, v)
			}
			cfg, err := Load(writeConfig(t, c.body), true)
			if c.wantErr != "" || c.check == nil {
				if err == nil {
					t.Fatalf("expected error, got cfg %#v", cfg)
				}
				if c.wantErr != "" && !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("error %q does not contain %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			c.check(t, cfg)
		})
	}
}
