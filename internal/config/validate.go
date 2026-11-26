package config

import (
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"path"
	"strings"

	"golang.org/x/net/http/httpguts"

	"github.com/mirkolenz/llmhop/internal/secrets"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

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

// isAddr reports whether s is an IP address.
func isAddr(s string) bool {
	_, err := netip.ParseAddr(s)

	return err == nil
}

// maxDataParallelSize bounds the ranks of a URL, far beyond any GPU count.
const maxDataParallelSize = 256

// validate checks every invariant and expands per-model header values in
// place, or with load unset only checks their references.
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

	owners, err := cfg.validateClients()
	if err != nil {
		return err
	}

	if load && cfg.ClientCredentials {
		if err := cfg.loadClientCredentials(owners); err != nil {
			return fmt.Errorf("clientCredentials: %w", err)
		}
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

	if m.DataParallelSize < 1 || m.DataParallelSize > maxDataParallelSize {
		return fmt.Errorf("dataParallelSize: must be between 1 and %d", maxDataParallelSize)
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

// validHeaderValue rejects an empty value and one that is no valid header
// value, for client names, which reach backends in the X-Llmhop-Client
// header.
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
