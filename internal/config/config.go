// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json/v2"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"

	"golang.org/x/net/http/httpguts"

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
	// HealthPath is the backend path GET /readiness probes. Empty skips the model.
	HealthPath string `json:"healthPath,omitempty"`
}

type Config struct {
	// Listen holds the addresses to serve on, each `host:port` or
	// `unix:///<socket path>`. Socket activation replaces it, so it may be empty.
	Listen       []string `json:"listen,omitempty"`
	MaxBodyBytes int64    `json:"maxBodyBytes,omitempty"`
	// MaxBufferedBytes bounds the bytes of all bodies held in memory at once to
	// read their JSON "model" field, until the backend starts its response.
	// Zero means unlimited.
	MaxBufferedBytes int64 `json:"maxBufferedBytes,omitempty"`
	// AuthTokens maps a token name to its secret.
	AuthTokens map[string]string `json:"authTokens,omitempty"`
	// AuthTokenCredentials is a systemd credential glob with a single trailing
	// `*`, as in ImportCredential=, whose matches join AuthTokens at startup,
	// each named by the part the `*` matched.
	AuthTokenCredentials string           `json:"authTokenCredentials,omitempty"`
	Models               map[string]Model `json:"models"`
}

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// DefaultMaxBufferedBytes bounds the bytes of request bodies buffered at once,
// thousands of typical requests or ten at the body size limit.
const DefaultMaxBufferedBytes = 1024 * 1024 * 1024

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

// RequiresAuth reports whether every route but health and readiness needs a
// bearer token. A credential glob requires one even while no credential
// matches, so removing the last client locks the gateway instead of opening it.
func (cfg *Config) RequiresAuth() bool {
	return len(cfg.AuthTokens) > 0 || cfg.AuthTokenCredentials != ""
}

// ParseListen splits a `listen` entry into the network and address that
// net.Listen takes. An empty host means every interface.
func ParseListen(raw string) (network, address string, err error) {
	if socket, ok := strings.CutPrefix(raw, "unix://"); ok {
		if !path.IsAbs(socket) || strings.ContainsAny(socket, "?#") {
			return "", "", fmt.Errorf("%q must be unix:///<absolute socket path>", raw)
		}

		return "unix", socket, nil
	}

	_, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", "", fmt.Errorf("%q must be host:port or unix:///<socket path>: %w", raw, err)
	}

	if _, err := strconv.ParseUint(port, 10, 16); err != nil {
		return "", "", fmt.Errorf("%q has an invalid port", raw)
	}

	return "tcp", raw, nil
}

// DecodeFile decodes the single JSON value of the file at path into v.
// Unknown keys are an error rather than a silent no-op: a misspelled
// optional field would otherwise fall back to its default unnoticed.
func DecodeFile(path string, v any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()

	return json.UnmarshalRead(f, v, json.RejectUnknownMembers(true))
}

// Load reads, parses and validates the config at path. With expandSecrets it
// also resolves every secret reference inside auth tokens and per-model
// headers; without it those are left verbatim, so a config can be validated
// where the environment variables and credential files it names do not exist.
func Load(path string, expandSecrets bool) (*Config, error) {
	cfg := &Config{
		MaxBodyBytes:     DefaultMaxBodyBytes,
		MaxBufferedBytes: DefaultMaxBufferedBytes,
	}

	if err := DecodeFile(path, cfg); err != nil {
		return nil, err
	}

	if err := cfg.validate(expandSecrets); err != nil {
		return nil, err
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

	for _, raw := range cfg.Listen {
		if _, _, err := ParseListen(raw); err != nil {
			return fmt.Errorf("listen: %w", err)
		}
	}

	for name, token := range cfg.AuthTokens {
		if name == "" {
			return errors.New("authTokens: name must not be empty")
		}

		v, err := secrets.Expand(token, load)
		if err == nil && !validToken(v) {
			err = errors.New("empty or invalid token")
		}

		if err != nil {
			return fmt.Errorf("authTokens.%s: %w", name, err)
		}

		cfg.AuthTokens[name] = v
	}

	if err := cfg.loadAuthTokenCredentials(load); err != nil {
		return fmt.Errorf("authTokenCredentials: %w", err)
	}

	for name, model := range cfg.Models {
		if !validModelName(name) {
			return fmt.Errorf("models.%s: name must be non-empty without leading, trailing or empty path segments", name)
		}

		if err := model.validate(load); err != nil {
			return fmt.Errorf("models.%s.%w", name, err)
		}
	}

	return nil
}

// validate checks m like Config.validate, expanding its header values in
// place. Errors start with the field they concern.
func (m Model) validate(load bool) error {
	// Probes join the path onto the backend URL, so only a path works.
	if m.HealthPath != "" && !validPath(m.HealthPath) {
		return fmt.Errorf("healthPath: %q must be an absolute path", m.HealthPath)
	}

	seen := make(map[string]bool, len(m.Headers))

	for header, value := range m.Headers {
		if !httpguts.ValidHeaderFieldName(header) {
			return fmt.Errorf("headers: invalid header name %q", header)
		}

		key := http.CanonicalHeaderKey(header)
		if seen[key] {
			return fmt.Errorf("headers: duplicate header %q", key)
		}

		seen[key] = true

		v, err := secrets.Expand(value, load)
		if err == nil && !httpguts.ValidHeaderFieldValue(v) {
			err = errors.New("invalid header value")
		}

		if err != nil {
			return fmt.Errorf("headers.%s: %w", header, err)
		}

		m.Headers[header] = v
	}

	return nil
}

// loadAuthTokenCredentials checks AuthTokenCredentials and, with load set,
// adds the tokens of the credentials it matches to AuthTokens.
func (cfg *Config) loadAuthTokenCredentials(load bool) error {
	glob := cfg.AuthTokenCredentials
	if glob == "" {
		return nil
	}

	prefix, ok := strings.CutSuffix(glob, "*")
	if !ok || strings.Contains(prefix, "*") {
		return fmt.Errorf("%q must end with a single *", glob)
	}

	if err := secrets.CheckCredentialName(prefix); err != nil {
		return err
	}

	if !load {
		return nil
	}

	creds, err := secrets.Credentials(prefix)
	if err != nil {
		return err
	}

	if cfg.AuthTokens == nil {
		cfg.AuthTokens = make(map[string]string, len(creds))
	}

	for name, token := range creds {
		if _, ok := cfg.AuthTokens[name]; ok {
			return fmt.Errorf("token %q is also in authTokens", name)
		}

		if !validToken(token) {
			return fmt.Errorf("credential %q: empty or invalid token", prefix+name)
		}

		cfg.AuthTokens[name] = token
	}

	return nil
}

// validToken rejects an empty token, which would authenticate
// `Authorization: Bearer `, and one that is no valid header value.
func validToken(v string) bool {
	return v != "" && httpguts.ValidHeaderFieldValue(v)
}

// validModelName allows `/` for names such as `org/name`, but no empty segment.
func validModelName(name string) bool {
	return name != "" && !strings.HasPrefix(name, "/") && !strings.HasSuffix(name, "/") && !strings.Contains(name, "//")
}

func validPath(p string) bool {
	u, err := url.Parse(p)

	return err == nil && u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/")
}
