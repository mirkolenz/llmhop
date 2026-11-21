// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside auth tokens and per-model headers.
package config

import (
	"encoding/json/jsontext"
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
	"github.com/mirkolenz/llmhop/internal/upstream"
)

type Model struct {
	// URLs are the servers of the model, each an absolute http(s) URL or
	// `unix:///<socket path>`, between which requests are balanced.
	URLs []string `json:"urls"`
	// Aliases are further names routed to the model and forwarded verbatim,
	// such as the LoRA adapters a vLLM server serves under their own names.
	Aliases []string          `json:"aliases,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	// Metadata adds members to the model's object in the models API,
	// such as `max_model_len`, or replaces `created` and `owned_by`,
	// while `id` and `object` are always llmhop's.
	Metadata map[string]jsontext.Value `json:"metadata,omitempty"`
	// Unlisted keeps a backend routable but hides it from the model catalog,
	// for services that are not inference models, such as a watermark detector.
	Unlisted bool `json:"unlisted,omitempty"`
	// MaxConcurrentRequests bounds the active proxied requests of the model
	// over all its URLs, so one busy model never starves another.
	// Zero means unlimited.
	// Like the timeouts, it is a uint32 to fit an int64 without overflowing.
	MaxConcurrentRequests uint32 `json:"maxConcurrentRequests,omitempty"`
	// QueueTimeoutSeconds is how long a request waits for a free slot of
	// MaxConcurrentRequests before it is rejected. Zero rejects it at once.
	QueueTimeoutSeconds uint32 `json:"queueTimeoutSeconds,omitempty"`
	// ResponseTimeoutSeconds bounds the wait for the response headers of a
	// backend. Zero means unlimited.
	ResponseTimeoutSeconds uint32 `json:"responseTimeoutSeconds,omitempty"`
	// DataParallelSize is the number of data-parallel ranks of every URL,
	// which requests with an affinity key are pinned to through vLLM's
	// `X-data-parallel-rank` header, one by default.
	DataParallelSize uint `json:"dataParallelSize,omitempty"`
	// FailoverSeconds is how long a server that refused a connection is
	// avoided.
	FailoverSeconds uint32 `json:"failoverSeconds"`
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
	AuthTokenCredentials string `json:"authTokenCredentials,omitempty"`
	// TrustedSockets maps a client name to a unix socket whose requests count
	// as that client's without a token, since the socket's permissions decide
	// who may connect. It requires auth tokens, as it is pointless without.
	TrustedSockets map[string]string `json:"trustedSockets,omitempty"`
	// Affinity lists the sources of the key keeping the requests of a
	// conversation on one server, tried in order: `header:<name>` or the
	// body's `prompt_cache_key`.
	Affinity []string         `json:"affinity,omitempty"`
	Models   map[string]Model `json:"models"`
}

// DefaultAffinity tries the session header of vLLM's router and SMG, then
// the key of OpenAI's prompt caching.
var DefaultAffinity = []string{"header:X-Session-Id", promptCacheKey}

// promptCacheKey is the affinity source of the body member of that name.
const promptCacheKey = "prompt_cache_key"

// maxDataParallelSize bounds the ranks of a URL, far beyond any GPU count.
const maxDataParallelSize = 256

// DefaultMaxBodyBytes bounds the size of a request body the router will buffer
// before forwarding. 100 MiB comfortably covers text completions and single
// base64-encoded images; bump it explicitly for larger multimodal payloads.
const DefaultMaxBodyBytes = 100 * 1024 * 1024

// DefaultMaxBufferedBytes bounds the bytes of request bodies buffered at once,
// thousands of typical requests or ten at the body size limit.
const DefaultMaxBufferedBytes = 1024 * 1024 * 1024

// Pattern reports whether a model name is a wildcard such as `openai/*`,
// which matches every name starting with the returned prefix.
func Pattern(name string) (prefix string, ok bool) {
	return strings.CutSuffix(name, "*")
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
	// Defaults that the decoded members replace, a list even when set to `[]`.
	cfg := &Config{
		MaxBodyBytes:     DefaultMaxBodyBytes,
		MaxBufferedBytes: DefaultMaxBufferedBytes,
		Affinity:         slices.Clone(DefaultAffinity),
	}

	if err := DecodeFile(path, cfg); err != nil {
		return nil, err
	}

	if err := cfg.validate(expandSecrets); err != nil {
		return nil, err
	}

	return cfg, nil
}

// UnmarshalJSONFrom decodes a model over its defaults, so that a member left
// out keeps its default while an explicit zero stays zero.
func (m *Model) UnmarshalJSONFrom(dec *jsontext.Decoder) error {
	type plain Model

	p := plain{FailoverSeconds: 5}
	if err := json.UnmarshalDecode(dec, &p); err != nil {
		return err
	}

	*m = Model(p)

	return nil
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

	// A token names one client, so that its requests always log the same.
	names := make(map[string]string, len(cfg.AuthTokens))

	for name, token := range cfg.AuthTokens {
		if !validClientName(name) {
			return fmt.Errorf("authTokens: invalid name %q", name)
		}

		if other, ok := names[token]; ok {
			return fmt.Errorf("authTokens: %s and %s share a token", min(name, other), max(name, other))
		}

		names[token] = name
	}

	if len(cfg.TrustedSockets) > 0 && !cfg.RequiresAuth() {
		return errors.New("trustedSockets require authTokens or authTokenCredentials")
	}

	sockets := make(map[string]bool, len(cfg.TrustedSockets))

	for name, socket := range cfg.TrustedSockets {
		switch {
		case !validClientName(name):
			return fmt.Errorf("trustedSockets: invalid name %q", name)
		case cfg.AuthTokens[name] != "":
			return fmt.Errorf("trustedSockets.%s: also names an auth token", name)
		// Requests carry the socket path as bound, so only that spelling matches.
		case !path.IsAbs(socket) || path.Clean(socket) != socket:
			return fmt.Errorf("trustedSockets.%s: %q must be a clean absolute socket path", name, socket)
		case len(cfg.Listen) > 0 && !slices.Contains(cfg.Listen, "unix://"+socket):
			return fmt.Errorf("trustedSockets.%s: %q is not in listen", name, socket)
		case sockets[socket]:
			return fmt.Errorf("trustedSockets.%s: %q is trusted twice", name, socket)
		}

		sockets[socket] = true
	}

	for _, source := range cfg.Affinity {
		header, isHeader := strings.CutPrefix(source, "header:")
		if isHeader && !httpguts.ValidHeaderFieldName(header) || !isHeader && source != promptCacheKey {
			return fmt.Errorf("affinity: %q must be header:<name> or %s", source, promptCacheKey)
		}
	}

	aliased := make(map[string]string)

	for name, model := range cfg.Models {
		if !validModelName(name) {
			return fmt.Errorf("models.%s: name must be non-empty without leading, trailing or empty path segments, with * only at its end", name)
		}

		if err := model.validate(load); err != nil {
			return fmt.Errorf("models.%s.%w", name, err)
		}

		// Every name and alias routes to one model.
		for _, alias := range model.Aliases {
			if _, ok := cfg.Models[alias]; ok {
				return fmt.Errorf("models.%s.aliases: %q is already a model", name, alias)
			}

			if owner, ok := aliased[alias]; ok {
				return fmt.Errorf("models.%s.aliases: %q is already an alias of models.%s", name, alias, owner)
			}

			aliased[alias] = name
		}
	}

	return nil
}

// validate checks m like Config.validate, expanding its header values in
// place. Errors start with the field they concern.
func (m Model) validate(load bool) error {
	if len(m.URLs) == 0 {
		return errors.New("urls: must not be empty")
	}

	if m.DataParallelSize > maxDataParallelSize {
		return fmt.Errorf("dataParallelSize: must not exceed %d", maxDataParallelSize)
	}

	for _, raw := range m.URLs {
		if _, err := upstream.Parse(raw, 0); err != nil {
			return fmt.Errorf("urls: %w", err)
		}
	}

	for _, alias := range m.Aliases {
		if _, wildcard := Pattern(alias); wildcard || !validModelName(alias) {
			return fmt.Errorf("aliases: %q must be a model name without *", alias)
		}
	}

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

// validClientName rejects an empty name and one that is no valid header
// value, since the name reaches backends in the X-Llmhop-Client header.
func validClientName(name string) bool {
	return name != "" && httpguts.ValidHeaderFieldValue(name)
}

// validToken rejects an empty token, which would authenticate
// `Authorization: Bearer `, and one that is no valid header value.
func validToken(v string) bool {
	return v != "" && httpguts.ValidHeaderFieldValue(v)
}

// validModelName allows `/` for names such as `org/name`, but no empty
// segment, and `*` only to end a wildcard, whose prefix may end with `/`.
func validModelName(name string) bool {
	prefix, wildcard := Pattern(name)
	if strings.Contains(prefix, "*") || strings.HasPrefix(prefix, "/") || strings.Contains(prefix, "//") {
		return false
	}

	return wildcard || prefix != "" && !strings.HasSuffix(prefix, "/")
}

func validPath(p string) bool {
	u, err := url.Parse(p)

	return err == nil && u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/")
}
