// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/mirkolenz/llmhop/internal/secrets"
)

type Model struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

type Config struct {
	Listen       string           `json:"listen"`
	MaxBodyBytes int64            `json:"maxBodyBytes,omitempty"`
	AuthTokens   []string         `json:"authTokens,omitempty"`
	Models       map[string]Model `json:"models"`
}

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// Load reads, parses and validates the config at path and expands every
// secret reference inside auth tokens and per-model headers.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{Listen: ":8080"}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	if len(cfg.Models) == 0 {
		return nil, fmt.Errorf("no models configured")
	}
	if cfg.MaxBodyBytes == 0 {
		cfg.MaxBodyBytes = DefaultMaxBodyBytes
	}
	for i, t := range cfg.AuthTokens {
		v, err := secrets.Expand(t)
		if err != nil {
			return nil, fmt.Errorf("authTokens[%d]: %w", i, err)
		}
		cfg.AuthTokens[i] = v
	}
	for name, model := range cfg.Models {
		for k, v := range model.Headers {
			expanded, err := secrets.Expand(v)
			if err != nil {
				return nil, fmt.Errorf("models.%s.headers.%s: %w", name, k, err)
			}
			model.Headers[k] = expanded
		}
	}
	return cfg, nil
}
