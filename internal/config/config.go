// Package config loads and validates llmhop's JSON configuration file,
// expanding any secret references inside per-model headers.
package config

import (
	"cmp"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"net"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
)

// Model is a backend served under a name, balanced over its URLs.
type Model struct {
	// URLs are the servers of the model, each an absolute http(s) URL or
	// `unix:///<socket path>`, between which requests are balanced.
	URLs []string `json:"urls"`
	// Aliases are further names routed to the model, such as its LoRA
	// adapters, each forwarded verbatim or as the model name it rewrites to.
	Aliases map[string]Alias `json:"aliases,omitempty"`
	// Headers are set on every request to the model, last, so they replace
	// those of the client. Their values may hold secret references.
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
	DataParallelSize uint32 `json:"dataParallelSize"`
	// FailoverSeconds is how long a server is avoided once it refused a
	// connection or failed several requests in a row.
	FailoverSeconds uint32 `json:"failoverSeconds"`
	// HealthPath is the backend path that GET /llmhop/readiness and the
	// metrics probe. Empty skips the model.
	HealthPath string `json:"healthPath,omitempty"`
	// MetricsPath is the backend path of its Prometheus metrics, such as the
	// token counts of vLLM, SGLang or llama.cpp, which GET /llmhop/metrics
	// collects from every URL. Empty skips the model.
	MetricsPath string `json:"metricsPath,omitempty"`
}

// Alias is a further name of a model.
type Alias struct {
	// Model replaces the "model" of a JSON body routed by the alias, such as
	// `<served>:<adapter>` for a LoRA adapter of SGLang. Empty forwards the
	// body verbatim.
	Model string `json:"model,omitempty"`
}

// Config is the configuration file of llmhop.
type Config struct {
	// Listen holds the listeners by name, which socket activation matches
	// to the names of the sockets it passes.
	Listen map[string]Listener `json:"listen,omitempty"`
	// MaxBodyBytes bounds the size of a request body. Zero means unlimited.
	MaxBodyBytes int64 `json:"maxBodyBytes,omitempty"`
	// MaxBufferedBytes bounds the bytes of all bodies held in memory at once to
	// read their JSON "model" field, until the backend starts its response.
	// Zero means unlimited.
	MaxBufferedBytes int64 `json:"maxBufferedBytes,omitempty"`
	// Clients are the callers of the API by name. Without any, every request
	// belongs to the anonymous client `""`, which Defaults limit.
	Clients map[string]Client `json:"clients,omitempty"`
	// ClientCredentials imports every credential named
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
	// Models are the backends by the name clients send, or a wildcard.
	Models map[string]Model `json:"models"`
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
	Host string `json:"host,omitempty"`
	// Port is the TCP port of the listener.
	Port uint16 `json:"port,omitempty"`
	// Socket is the absolute path of the unix socket of the listener.
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

// Client is a caller of the API, authenticated by exactly one of a key hash
// or a client listener, with its own policy fields over those of its policy.
type Client struct {
	Policy
	// KeyHash is the hash of the bearer token of the client.
	KeyHash apikey.Hash `json:"keyHash,omitzero"`
	// Listener names a unix socket listener whose requests count as the
	// client's without a key, since the socket's permissions decide who may
	// connect.
	Listener string `json:"listener,omitempty"`
	// PolicyName names the policy of the client in Policies.
	PolicyName string `json:"policy,omitempty"`
	// ExpiresAt ends the validity of the client, unless zero.
	ExpiresAt time.Time `json:"expiresAt,omitzero"`
}

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
// also resolves every secret reference inside per-model headers and imports
// the client credentials. Without it, references are left verbatim, so a
// config can be validated where the environment variables and credentials it
// names do not exist.
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

	p := plain{FailoverSeconds: 5, DataParallelSize: 1}
	if err := json.UnmarshalDecode(dec, &p); err != nil {
		return err
	}

	*m = Model(p)

	return nil
}

// KnownPolicy reports whether name is empty or names a policy.
func (cfg *Config) KnownPolicy(name string) bool {
	_, ok := cfg.Policies[name]

	return name == "" || ok
}
