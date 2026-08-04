// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"

	"github.com/mirkolenz/llmhop/internal/secrets"
)

type Model struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

type Config struct {
	// Host is the interface to bind to. Empty means every interface.
	Host         string           `json:"host,omitempty"`
	Port         int              `json:"port,omitempty"`
	MaxBodyBytes int64            `json:"maxBodyBytes,omitempty"`
	AuthTokens   []string         `json:"authTokens,omitempty"`
	Models       map[string]Model `json:"models"`
}

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// DefaultPort is the port llmhop listens on when the config sets none.
const DefaultPort = 8080

// Listen renders the host and port as a net.Listen address.
func (cfg *Config) Listen() string {
	return net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
}

// Load reads, parses and validates the config at path. With expandSecrets it
// also resolves every secret reference inside auth tokens and per-model
// headers; without it those are left verbatim, so a config can be validated
// where the environment variables and credential files it names do not exist.
func Load(path string, expandSecrets bool) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	cfg := &Config{}
	dec := json.NewDecoder(f)
	// Unknown keys are an error rather than a silent no-op: a misspelled
	// optional field would otherwise fall back to its default unnoticed.
	dec.DisallowUnknownFields()

	if err := dec.Decode(cfg); err != nil {
		return nil, err
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	if cfg.Port == 0 {
		cfg.Port = DefaultPort
	}

	if cfg.MaxBodyBytes == 0 {
		cfg.MaxBodyBytes = DefaultMaxBodyBytes
	}

	if expandSecrets {
		if err := cfg.expand(); err != nil {
			return nil, err
		}
	}

	return cfg, nil
}

// validate checks every invariant that does not depend on secret expansion, so
// a `-check` run rejects exactly the configs that would fail at startup.
func (cfg *Config) validate() error {
	if len(cfg.Models) == 0 {
		return fmt.Errorf("no models configured")
	}

	for name, model := range cfg.Models {
		u, err := url.Parse(model.URL)
		if err != nil {
			return fmt.Errorf("models.%s: invalid url %q: %w", name, model.URL, err)
		}

		// `url.Parse` happily accepts `127.0.0.1:8000` (scheme `127.0.0.1`),
		// which would only surface as a proxy error per request.
		if (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fmt.Errorf("models.%s: url %q must be an absolute http(s) URL", name, model.URL)
		}
	}

	return nil
}

// expand resolves the secret references inside auth tokens and per-model
// headers in place.
func (cfg *Config) expand() error {
	for i, t := range cfg.AuthTokens {
		v, err := secrets.Expand(t)
		if err != nil {
			return fmt.Errorf("authTokens[%d]: %w", i, err)
		}

		cfg.AuthTokens[i] = v
	}

	for name, model := range cfg.Models {
		for k, v := range model.Headers {
			expanded, err := secrets.Expand(v)
			if err != nil {
				return fmt.Errorf("models.%s.headers.%s: %w", name, k, err)
			}

			model.Headers[k] = expanded
		}
	}

	return nil
}
