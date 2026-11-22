// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside client keys and per-model headers.
package config

import (
	"cmp"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/http/httpguts"

	"github.com/mirkolenz/llmhop/internal/secrets"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

type Model struct {
	// URLs are the servers of the model, each an absolute http(s) URL or
	// `unix:///<socket path>`, between which requests are balanced.
	URLs []string `json:"urls"`
	// Aliases are further names routed to the model, such as its LoRA
	// adapters, each forwarded verbatim or as the model name it rewrites to.
	Aliases map[string]Alias  `json:"aliases,omitempty"`
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
	// MaxConcurrentRequests or of its client before it is rejected. Zero
	// rejects it at once.
	QueueTimeoutSeconds uint32 `json:"queueTimeoutSeconds,omitempty"`
	// ResponseTimeoutSeconds bounds the wait for the response headers of a
	// backend. Zero means unlimited.
	ResponseTimeoutSeconds uint32 `json:"responseTimeoutSeconds,omitempty"`
	// StreamIdleTimeoutSeconds aborts an event stream that sends nothing for
	// that long. Zero means unlimited.
	StreamIdleTimeoutSeconds uint32 `json:"streamIdleTimeoutSeconds,omitempty"`
	// DataParallelSize is the number of data-parallel ranks of every URL,
	// which requests with an affinity key are pinned to through the
	// `X-Data-Parallel-Rank` header of vLLM and SGLang, one by default.
	DataParallelSize uint `json:"dataParallelSize,omitempty"`
	// FailoverSeconds is how long a server is avoided once it refused a
	// connection or failed several requests in a row.
	FailoverSeconds uint32 `json:"failoverSeconds"`
	// HealthPath is the backend path that GET /llmhop/readiness and the
	// metrics probe. Empty skips the model.
	HealthPath string `json:"healthPath,omitempty"`
}

// Alias is a further name of a model.
type Alias struct {
	// Model replaces the "model" of a JSON body routed by the alias, such as
	// `<served>:<adapter>` for a LoRA adapter of SGLang. Empty forwards the
	// body verbatim.
	Model string `json:"model,omitempty"`
}

type Config struct {
	// Listen holds the listeners by name, which socket activation matches
	// to the names of the sockets it passes.
	Listen       map[string]Listener `json:"listen,omitempty"`
	MaxBodyBytes int64               `json:"maxBodyBytes,omitempty"`
	// MaxBufferedBytes bounds the bytes of all bodies held in memory at once to
	// read their JSON "model" field, until the backend starts its response.
	// Zero means unlimited.
	MaxBufferedBytes int64 `json:"maxBufferedBytes,omitempty"`
	// Clients are the callers of the API by name. Without any, every request
	// belongs to the anonymous client `""`, which Defaults limit.
	Clients map[string]Client `json:"clients,omitempty"`
	// ClientCredentials imports every systemd credential named
	// `llmhop.api-key.<client>` as a further client, unless declared.
	ClientCredentials bool `json:"clientCredentials,omitempty"`
	// Policies are the named policies a client may refer to.
	Policies map[string]Policy `json:"policies,omitempty"`
	// Defaults is the policy below every client and its policy.
	Defaults Policy `json:"defaults,omitzero"`
	// CORSOrigins lists the origins whose pages may call the API with a
	// bearer token, or `*` for every origin. It requires clients, since a
	// page would otherwise reach the backends with nothing to stop it.
	CORSOrigins []string `json:"corsOrigins,omitempty"`
	// Affinity lists the sources of the key keeping the requests of a
	// conversation on one server, tried in order.
	Affinity []AffinitySource `json:"affinity,omitempty"`
	Models   map[string]Model `json:"models"`
}

// AffinitySource carries the affinity key in exactly one of a request
// header or a string at a path of members into the JSON body. Pinned keeps
// its requests on their server under any load or failure, since their state
// lives there.
type AffinitySource struct {
	Header string   `json:"header,omitempty"`
	Body   []string `json:"body,omitempty"`
	Pinned bool     `json:"pinned,omitempty"`
}

// Listener is a socket llmhop serves on, a TCP Port on Host, a unix Socket,
// or without either a socket systemd passes by the name of the listener.
type Listener struct {
	// Host is the address Port is bound to, every interface if empty.
	Host   string `json:"host,omitempty"`
	Port   uint16 `json:"port,omitempty"`
	Socket string `json:"socket,omitempty"`
	// Metrics serves the metrics of llmhop without a key.
	Metrics bool `json:"metrics,omitempty"`
}

// Network returns the network and address that net.Listen takes, both
// empty without a port or socket.
func (l Listener) Network() (network, address string) {
	switch {
	case l.Socket != "":
		return "unix", l.Socket
	case l.Port != 0:
		return "tcp", net.JoinHostPort(l.Host, strconv.FormatUint(uint64(l.Port), 10))
	}

	return "", ""
}

// validate checks the fields of l. Errors start with the field they concern.
func (l Listener) validate() error {
	switch {
	case l.Socket != "" && (l.Port != 0 || l.Host != ""):
		return errors.New("socket: must not be set beside host or port")
	case l.Host != "" && l.Port == 0:
		return errors.New("host: requires a port")
	case l.Host != "" && !isAddr(l.Host):
		// Socket activation compares it with the address of a passed socket.
		return fmt.Errorf("host: %q must be an IP address", l.Host)
	case l.Socket != "" && !path.IsAbs(l.Socket):
		return fmt.Errorf("socket: %q must be an absolute path", l.Socket)
	}

	return nil
}

// Addr returns the address Port is bound to, unspecified for every
// interface.
func (l Listener) Addr() netip.Addr {
	addr, _ := netip.ParseAddr(cmp.Or(l.Host, "::"))

	return addr.Unmap()
}

// SameBindings reports whether the listeners b bind what a binds, which
// only a restart changes, where a missing listener binds nothing as one
// without a port or socket does.
func SameBindings(a, b map[string]Listener) bool {
	same := func(l, o Listener) bool {
		return l.Socket == o.Socket && l.Port == o.Port && (l.Port == 0 || l.Addr() == o.Addr())
	}

	for name, l := range a {
		if !same(l, b[name]) {
			return false
		}
	}

	for name, l := range b {
		if !same(l, a[name]) {
			return false
		}
	}

	return true
}

// isAddr reports whether s is an IP address.
func isAddr(s string) bool {
	_, err := netip.ParseAddr(s)

	return err == nil
}

// Policy decides the models a client may use, its limits and its share of
// a queue. A nil field is unset, so a lower layer decides it, while a
// zero one means no limit.
type Policy struct {
	// Models allows the model names, aliases and wildcards it lists.
	Models []string `json:"models,omitempty"`
	// MaxConcurrentRequests bounds the requests in flight at once.
	MaxConcurrentRequests *uint32 `json:"maxConcurrentRequests,omitempty"`
	// RequestsPerMinute refills a token bucket of requests.
	RequestsPerMinute *uint32 `json:"requestsPerMinute,omitempty"`
	// Weight is the share of a client among those waiting for a saturated
	// model, one by default.
	Weight *uint32 `json:"weight,omitempty"`
}

// Over layers p over base, the fields set in p winning.
func (p Policy) Over(base Policy) Policy {
	if p.Models == nil {
		p.Models = base.Models
	}

	p.MaxConcurrentRequests = cmp.Or(p.MaxConcurrentRequests, base.MaxConcurrentRequests)
	p.RequestsPerMinute = cmp.Or(p.RequestsPerMinute, base.RequestsPerMinute)
	p.Weight = cmp.Or(p.Weight, base.Weight)

	return p
}

// Client is a caller of the API, authenticated by exactly one of a key or a
// client listener, with its own policy fields over those of its policy.
type Client struct {
	Policy
	// Key is the bearer token of the client.
	Key string `json:"key,omitempty"`
	// Listener names a unix socket listener whose requests count as the
	// client's without a key, since the socket's permissions decide who may
	// connect.
	Listener string `json:"listener,omitempty"`
	// PolicyName names the policy of the client in Policies.
	PolicyName string `json:"policy,omitempty"`
	// ExpiresAt ends the validity of the client, unless zero.
	ExpiresAt time.Time `json:"expiresAt,omitzero"`
}

// clientCredentialPrefix starts the names of the credentials that
// ClientCredentials imports, each as the client named by the rest.
const clientCredentialPrefix = "llmhop.api-key."

// EffectivePolicy layers the client over its policy and the defaults, the
// zero client being the anonymous one.
func (cfg *Config) EffectivePolicy(c Client) Policy {
	return c.Policy.Over(cfg.Policies[c.PolicyName]).Over(cfg.Defaults)
}

// DefaultAffinity tries the session header of vLLM's router and SMG, the
// key of OpenAI's prompt caching, then the session of SGLang, whose state
// lives on one server.
var DefaultAffinity = []AffinitySource{
	{Header: "X-Session-Id"},
	{Body: []string{"prompt_cache_key"}},
	{Body: []string{"session_params", "id"}, Pinned: true},
}

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
// client. ClientCredentials requires one even while no credential exists,
// so removing the last client locks the gateway instead of opening it.
func (cfg *Config) RequiresAuth() bool {
	return len(cfg.Clients) > 0 || cfg.ClientCredentials
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
// also resolves every secret reference inside client keys and per-model
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

// validate checks every invariant and expands client keys and per-model
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

	for name, l := range cfg.Listen {
		if name == "" {
			return errors.New("listen: empty listener name")
		}

		if err := l.validate(); err != nil {
			return fmt.Errorf("listen.%s.%w", name, err)
		}
	}

	if err := cfg.Defaults.validate(); err != nil {
		return fmt.Errorf("defaults.%w", err)
	}

	for name, p := range cfg.Policies {
		if name == "" {
			// It would layer under every client without a policy.
			return errors.New("policies: empty policy name")
		}

		if err := p.validate(); err != nil {
			return fmt.Errorf("policies.%s.%w", name, err)
		}
	}

	// Only declared keys hold references, the credentials are their values.
	for name, c := range cfg.Clients {
		key, err := secrets.Expand(c.Key, load)
		if err != nil {
			return fmt.Errorf("clients.%s.key: %w", name, err)
		}

		c.Key = key
		cfg.Clients[name] = c
	}

	if load && cfg.ClientCredentials {
		if err := cfg.loadClientCredentials(); err != nil {
			return fmt.Errorf("clientCredentials: %w", err)
		}
	}

	if err := cfg.validateClients(); err != nil {
		return err
	}

	for i, source := range cfg.Affinity {
		if (source.Header == "") == (len(source.Body) == 0) || source.Header != "" && !httpguts.ValidHeaderFieldName(source.Header) {
			return fmt.Errorf("affinity.%d: must set exactly one of a valid header or a non-empty body path", i)
		}
	}

	if len(cfg.CORSOrigins) > 0 && !cfg.RequiresAuth() {
		return errors.New("corsOrigins require clients or clientCredentials")
	}

	for _, origin := range cfg.CORSOrigins {
		if !validOrigin(origin) && (origin != "*" || len(cfg.CORSOrigins) > 1) {
			return fmt.Errorf("corsOrigins: %q must be a scheme://host[:port], or the only entry *", origin)
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
		for alias := range model.Aliases {
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

	for name := range m.Aliases {
		if _, wildcard := Pattern(name); wildcard || !validModelName(name) {
			return fmt.Errorf("aliases: %q must be a model name without *", name)
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

// validate checks the model patterns of p. Errors start with the field they
// concern.
func (p Policy) validate() error {
	for _, pattern := range p.Models {
		if !validModelName(pattern) {
			return fmt.Errorf("models: invalid name or wildcard %q", pattern)
		}
	}

	return nil
}

// validateClients checks the clients, whose keys are expanded and
// credentials loaded.
func (cfg *Config) validateClients() error {
	// A key names one client, so that its requests always log the same.
	keys := make(map[string]string, len(cfg.Clients))
	listeners := make(map[string]string, len(cfg.Clients))

	for name, c := range cfg.Clients {
		if err := cfg.validateClient(name, c); err != nil {
			return err
		}

		if c.Listener == "" {
			if other, ok := keys[c.Key]; ok {
				return fmt.Errorf("clients: %s and %s share a key", min(name, other), max(name, other))
			}

			keys[c.Key] = name

			continue
		}

		l, ok := cfg.Listen[c.Listener]
		network, _ := l.Network()

		// The requests of a passed socket only count as a unix socket's.
		switch other, shared := listeners[c.Listener]; {
		case !ok:
			return fmt.Errorf("clients.%s.listener: %q is not in listen", name, c.Listener)
		case network == "tcp":
			return fmt.Errorf("clients.%s.listener: %q is no unix socket", name, c.Listener)
		case shared:
			return fmt.Errorf("clients: %s and %s share a listener", min(name, other), max(name, other))
		}

		listeners[c.Listener] = name
	}

	return nil
}

// validateClient checks a client on its own.
func (cfg *Config) validateClient(name string, c Client) error {
	switch {
	case !validHeaderValue(name):
		return fmt.Errorf("clients: invalid name %q", name)
	case (c.Key == "") == (c.Listener == ""):
		return fmt.Errorf("clients.%s: must set exactly one of key or listener", name)
	case c.Listener == "" && !validHeaderValue(c.Key):
		return fmt.Errorf("clients.%s.key: empty or invalid key", name)
	case !cfg.knownPolicy(c.PolicyName):
		return fmt.Errorf("clients.%s.policy: unknown policy %q", name, c.PolicyName)
	}

	if err := c.validate(); err != nil {
		return fmt.Errorf("clients.%s.%w", name, err)
	}

	return nil
}

// loadClientCredentials adds the client of every credential named with
// clientCredentialPrefix, unless it is declared. A credential holds the bare
// key or a JSON object with only what rotates with the key. An invalid one
// is logged and skipped, since the config it outlives, such as by a
// renamed policy, must still start.
func (cfg *Config) loadClientCredentials() error {
	names, err := secrets.CredentialNames()
	if err != nil {
		return err
	}

	for _, name := range names {
		client, ok := strings.CutPrefix(name, clientCredentialPrefix)
		if _, declared := cfg.Clients[client]; !ok || client == "" || declared {
			continue
		}

		c, err := cfg.credentialClient(client, name)
		if err != nil {
			slog.Error("skipping client credential", "credential", name, "err", err)

			continue
		}

		if cfg.Clients == nil {
			cfg.Clients = make(map[string]Client)
		}

		cfg.Clients[client] = c
	}

	return nil
}

// credentialClient returns the valid client called name of the credential,
// holding its bare key or a JSON credential.
func (cfg *Config) credentialClient(name, credential string) (Client, error) {
	value, err := secrets.Credential(credential)
	if err != nil {
		return Client{}, err
	}

	var c struct {
		Key       string    `json:"key"`
		Policy    string    `json:"policy,omitempty"`
		ExpiresAt time.Time `json:"expiresAt,omitzero"`
	}

	if jsontext.Value(value).Kind() != '{' {
		c.Key = value
	} else if err := json.Unmarshal([]byte(value), &c, json.RejectUnknownMembers(true)); err != nil {
		return Client{}, err
	}

	client := Client{Key: c.Key, PolicyName: c.Policy, ExpiresAt: c.ExpiresAt}

	return client, cfg.validateClient(name, client)
}

// knownPolicy reports whether name is empty or names a policy.
func (cfg *Config) knownPolicy(name string) bool {
	_, ok := cfg.Policies[name]

	return name == "" || ok
}

// validHeaderValue rejects an empty value and one that is no valid header
// value, for client names, which reach backends in the X-Llmhop-Client
// header, and keys, where an empty one would authenticate `Bearer `.
func validHeaderValue(v string) bool {
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

// validOrigin accepts a bare http(s) origin, without path or userinfo.
func validOrigin(origin string) bool {
	u, err := url.Parse(origin)

	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" &&
		u.Scheme+"://"+u.Host == origin
}

func validPath(p string) bool {
	u, err := url.Parse(p)

	return err == nil && u.Scheme == "" && u.Host == "" && strings.HasPrefix(u.Path, "/")
}
