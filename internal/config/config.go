// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"

	"github.com/mirkolenz/llmhop/internal/secrets"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

type Model struct {
	// URL is an absolute http(s) URL or `unix:///<socket path>`.
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	// Unlisted keeps a backend routable but hides it from the model catalog,
	// for services that are not inference models, such as a watermark detector.
	Unlisted bool `json:"unlisted,omitempty"`
}

type Config struct {
	// Host is the interface to bind to. Empty means every interface.
	Host                  string           `json:"host,omitempty"`
	Port                  int              `json:"port,omitempty"`
	MaxBodyBytes          int64            `json:"maxBodyBytes,omitempty"`
	MaxConcurrentRequests int              `json:"maxConcurrentRequests,omitempty"`
	AuthTokens            []string         `json:"authTokens,omitempty"`
	Models                map[string]Model `json:"models"`
}

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// DefaultMaxConcurrentRequests bounds the number of active proxied requests.
const DefaultMaxConcurrentRequests = 8

// DefaultPort is the port llmhop listens on when the config sets none.
const DefaultPort = 8080

// Listed returns the sorted names of the models advertised in the catalog.
// Unlisted backends are omitted, but stay routable by name.
func (cfg *Config) Listed() []string {
	names := make([]string, 0, len(cfg.Models))

	for name, model := range cfg.Models {
		if !model.Unlisted {
			names = append(names, name)
		}
	}

	slices.Sort(names)

	return names
}

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
	defer func() { _ = f.Close() }()

	cfg := &Config{
		MaxBodyBytes:          DefaultMaxBodyBytes,
		MaxConcurrentRequests: DefaultMaxConcurrentRequests,
	}
	dec := json.NewDecoder(f)
	// Unknown keys are an error rather than a silent no-op: a misspelled
	// optional field would otherwise fall back to its default unnoticed.
	dec.DisallowUnknownFields()

	if err := dec.Decode(cfg); err != nil {
		return nil, err
	}

	if err := dec.Decode(&struct{}{}); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("multiple JSON values in config")
		}

		return nil, err
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	if cfg.Port == 0 {
		cfg.Port = DefaultPort
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
	if cfg.Port < 0 || cfg.Port > 65535 {
		return fmt.Errorf("port %d is outside 0..65535", cfg.Port)
	}

	if cfg.MaxBodyBytes < 0 {
		return fmt.Errorf("maxBodyBytes must not be negative")
	}

	if cfg.MaxConcurrentRequests < 0 {
		return fmt.Errorf("maxConcurrentRequests must not be negative")
	}

	for i, token := range cfg.AuthTokens {
		if err := validateAuthToken(token); err != nil {
			return fmt.Errorf("authTokens[%d]: %w", i, err)
		}

		if err := secrets.ValidateReferences(token); err != nil {
			return fmt.Errorf("authTokens[%d]: %w", i, err)
		}
	}

	if len(cfg.Models) == 0 {
		return fmt.Errorf("no models configured")
	}

	for name, model := range cfg.Models {
		if name == "" {
			return fmt.Errorf("model name must not be empty")
		}

		if _, err := upstream.Parse(model.URL); err != nil {
			return fmt.Errorf("models.%s: %w", name, err)
		}

		if err := validateHeaders(name, model.Headers); err != nil {
			return err
		}
	}

	return nil
}

func validateAuthToken(token string) error {
	if token == "" {
		return fmt.Errorf("empty token")
	}

	if !validHeaderValue(token) {
		return fmt.Errorf("invalid token")
	}

	return nil
}

func validateHeaders(model string, headers map[string]string) error {
	seen := make(map[string]bool, len(headers))

	for header, value := range headers {
		if !validHeaderName(header) {
			return fmt.Errorf("models.%s.headers: invalid header name %q", model, header)
		}

		key := strings.ToLower(header)
		if seen[key] {
			return fmt.Errorf("models.%s.headers: duplicate header %q", model, key)
		}

		seen[key] = true

		if !validHeaderValue(value) {
			return fmt.Errorf("models.%s.headers.%s: invalid header value", model, header)
		}

		if err := secrets.ValidateReferences(value); err != nil {
			return fmt.Errorf("models.%s.headers.%s: %w", model, header, err)
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

		if err := validateAuthToken(v); err != nil {
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

			if !validHeaderValue(expanded) {
				return fmt.Errorf("models.%s.headers.%s: invalid header value", name, k)
			}

			model.Headers[k] = expanded
		}
	}

	return nil
}

func validHeaderName(name string) bool {
	if name == "" {
		return false
	}

	for i := range len(name) {
		c := name[i]
		if c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || strings.ContainsRune("!#$%&'*+-.^_`|~", rune(c)) {
			continue
		}

		return false
	}

	return true
}

func validHeaderValue(value string) bool {
	for i := range len(value) {
		c := value[i]
		if c < ' ' && c != '\t' || c == 0x7f {
			return false
		}
	}

	return true
}
