// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
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
			return nil, errors.New("multiple JSON values in config")
		}

		return nil, err
	}

	if err := cfg.validate(); err != nil {
		return nil, err
	}

	if cfg.Port == 0 {
		cfg.Port = DefaultPort
	}

	resolve := secrets.Expand
	if !expandSecrets {
		resolve = func(s string) (string, error) { return s, secrets.Validate(s) }
	}

	if err := cfg.resolveSecrets(resolve); err != nil {
		return nil, err
	}

	return cfg, nil
}

// validate checks every invariant of values that cannot carry secrets.
func (cfg *Config) validate() error {
	if cfg.Port < 0 || cfg.Port > 65535 {
		return fmt.Errorf("port %d is outside 0..65535", cfg.Port)
	}

	if cfg.MaxBodyBytes < 0 {
		return errors.New("maxBodyBytes must not be negative")
	}

	if cfg.MaxConcurrentRequests < 0 {
		return errors.New("maxConcurrentRequests must not be negative")
	}

	if len(cfg.Models) == 0 {
		return errors.New("no models configured")
	}

	for name, model := range cfg.Models {
		if name == "" {
			return errors.New("model name must not be empty")
		}

		if _, err := upstream.Parse(model.URL); err != nil {
			return fmt.Errorf("models.%s: %w", name, err)
		}

		seen := make(map[string]bool, len(model.Headers))

		for header := range model.Headers {
			if !validHeaderName(header) {
				return fmt.Errorf("models.%s.headers: invalid header name %q", name, header)
			}

			key := http.CanonicalHeaderKey(header)
			if seen[key] {
				return fmt.Errorf("models.%s.headers: duplicate header %q", name, key)
			}

			seen[key] = true
		}
	}

	return nil
}

// resolveSecrets passes auth tokens and per-model header values through
// resolve in place and validates the results. Raw references are valid
// header values, so the same checks serve `-check` runs and startup.
func (cfg *Config) resolveSecrets(resolve func(string) (string, error)) error {
	for i, token := range cfg.AuthTokens {
		v, err := resolve(token)
		if err == nil {
			err = validateAuthToken(v)
		}

		if err != nil {
			return fmt.Errorf("authTokens[%d]: %w", i, err)
		}

		cfg.AuthTokens[i] = v
	}

	for name, model := range cfg.Models {
		for k, value := range model.Headers {
			v, err := resolve(value)
			if err == nil && !validHeaderValue(v) {
				err = errors.New("invalid header value")
			}

			if err != nil {
				return fmt.Errorf("models.%s.headers.%s: %w", name, k, err)
			}

			model.Headers[k] = v
		}
	}

	return nil
}

func validateAuthToken(token string) error {
	if token == "" {
		return errors.New("empty token")
	}

	if !validHeaderValue(token) {
		return errors.New("invalid token")
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
