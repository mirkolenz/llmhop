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
	os.Unsetenv("LLMHOP_CFG_MISSING")
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
			name:    "requires absolute model URLs",
			body:    `{"models": {"m": {"url": "localhost:8000"}}}`,
			wantErr: "absolute http(s) URL",
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
			name: "custom maxBodyBytes",
			body: `{"maxBodyBytes": 4096, "models": {"m": {"url": "http://x"}}}`,
			check: func(t *testing.T, cfg *Config) {
				if cfg.MaxBodyBytes != 4096 {
					t.Fatalf("got %d", cfg.MaxBodyBytes)
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
			os.Unsetenv("LLMHOP_CFG_MISSING")
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
