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
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"

	"github.com/mirkolenz/llmhop/internal/secrets"
)

type Model struct {
	// URL is an absolute http(s) URL or `unix:///<socket path>`.
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
	// Unlisted keeps a backend routable but hides it from the model catalog,
	// for services that are not inference models, such as a watermark detector.
	Unlisted bool `json:"unlisted,omitempty"`
	// MaxConcurrentRequests bounds the active proxied requests per model,
	// so one busy backend never starves another. Zero means unlimited.
	MaxConcurrentRequests uint `json:"maxConcurrentRequests,omitempty"`
	// Health is the backend path GET /readiness probes. Empty skips the model.
	Health string `json:"health,omitempty"`
}

type Config struct {
	// Host is the interface to bind to. Empty means every interface.
	Host         string `json:"host,omitempty"`
	Port         uint16 `json:"port,omitempty"`
	MaxBodyBytes int64  `json:"maxBodyBytes,omitempty"`
	// MaxBufferedBytes bounds the bytes of all bodies held in memory at once to
	// read their JSON "model" field, until the backend starts its response.
	// Zero means unlimited.
	MaxBufferedBytes int64            `json:"maxBufferedBytes,omitempty"`
	AuthTokens       []string         `json:"authTokens,omitempty"`
	Models           map[string]Model `json:"models"`
}

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// DefaultMaxBufferedBytes bounds the bytes of request bodies buffered at once,
// thousands of typical requests or ten at the body size limit.
const DefaultMaxBufferedBytes = 1024 * 1024 * 1024

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
	return net.JoinHostPort(cfg.Host, strconv.Itoa(int(cfg.Port)))
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
		MaxBodyBytes:     DefaultMaxBodyBytes,
		MaxBufferedBytes: DefaultMaxBufferedBytes,
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

	if err := cfg.validate(expandSecrets); err != nil {
		return nil, err
	}

	if cfg.Port == 0 {
		cfg.Port = DefaultPort
	}

	return cfg, nil
}

// validate checks every invariant and expands auth tokens and per-model
// header values in place, or with load unset only checks their references.
// Raw references are valid header values, so the same checks serve
// `llmhop check` and startup.
func (cfg *Config) validate(load bool) error {
	if len(cfg.Models) == 0 {
		return errors.New("no models configured")
	}

	if cfg.MaxBodyBytes < 0 {
		return errors.New("maxBodyBytes must not be negative")
	}

	if cfg.MaxBufferedBytes < 0 {
		return errors.New("maxBufferedBytes must not be negative")
	}

	for i, token := range cfg.AuthTokens {
		v, err := secrets.Expand(token, load)
		// An empty token would authenticate `Authorization: Bearer `.
		if err == nil && (v == "" || !validHeaderValue(v)) {
			err = errors.New("empty or invalid token")
		}

		if err != nil {
			return fmt.Errorf("authTokens[%d]: %w", i, err)
		}

		cfg.AuthTokens[i] = v
	}

	for name, model := range cfg.Models {
		if name == "" {
			return errors.New("model name must not be empty")
		}

		// Probes join the path onto the backend URL, so only a path works.
		if model.Health != "" && !validPath(model.Health) {
			return fmt.Errorf("models.%s.health: %q must be an absolute path", name, model.Health)
		}

		seen := make(map[string]bool, len(model.Headers))

		for header, value := range model.Headers {
			if !validHeaderName(header) {
				return fmt.Errorf("models.%s.headers: invalid header name %q", name, header)
			}

			key := http.CanonicalHeaderKey(header)
			if seen[key] {
				return fmt.Errorf("models.%s.headers: duplicate header %q", name, key)
			}

			seen[key] = true

			v, err := secrets.Expand(value, load)
			if err == nil && !validHeaderValue(v) {
				err = errors.New("invalid header value")
			}

			if err != nil {
				return fmt.Errorf("models.%s.headers.%s: %w", name, header, err)
			}

			model.Headers[header] = v
		}
	}

	return nil
}

func validPath(p string) bool {
	u, err := url.Parse(p)

	return err == nil && u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/")
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
