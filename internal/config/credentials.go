package config

import (
	"encoding/json/v2"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"strings"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/secrets"
)

// clientCredentialPrefix starts the names of the credentials that
// ClientCredentials imports, each as the client named by the rest.
const clientCredentialPrefix = "llmhop.api-key."

// CredentialName returns the name of the credential of a client.
func CredentialName(client string) string {
	return clientCredentialPrefix + client
}

// CheckCredentialClient fails unless client may have a credential.
func CheckCredentialClient(client string) error {
	if client == "" {
		return errors.New("empty client name")
	}

	return secrets.CheckCredentialName(CredentialName(client))
}

// CredentialClient returns the client of a credential name, if any.
func CredentialClient(credential string) (string, bool) {
	client, ok := strings.CutPrefix(credential, clientCredentialPrefix)

	return client, ok && client != ""
}

// Credential is a client that ClientCredentials imports, holding only what
// rotates with its key.
type Credential struct {
	KeyHash   apikey.Hash `json:"keyHash"`
	Policy    string      `json:"policy,omitempty"`
	ExpiresAt time.Time   `json:"expiresAt,omitzero"`
}

// ParseCredential parses the JSON object of a credential, which must hold a
// key hash.
func ParseCredential(data []byte) (Credential, error) {
	var c Credential

	if err := json.Unmarshal(data, &c, json.RejectUnknownMembers(true)); err != nil {
		return Credential{}, err
	}

	if c.KeyHash == (apikey.Hash{}) {
		return Credential{}, errors.New("keyHash: must be set")
	}

	return c, nil
}

// keyOwners maps each key hash to its client, since a token finds one
// client.
type keyOwners map[apikey.Hash]string

// claim records the key hash of the client name, failing if another client
// holds it.
func (k keyOwners) claim(name string, hash apikey.Hash) error {
	if hash == (apikey.Hash{}) {
		return nil
	}

	if other, ok := k[hash]; ok && other != name {
		return fmt.Errorf("clients: %s and %s share a key", min(name, other), max(name, other))
	}

	k[hash] = name

	return nil
}

// validateClients checks the declared clients, returning the owners of their
// keys.
func (cfg *Config) validateClients() (keyOwners, error) {
	listeners := make(map[string]string, len(cfg.Clients))
	owners := make(keyOwners, len(cfg.Clients))

	for name, c := range cfg.Clients {
		if err := cfg.validateClient(name, c); err != nil {
			return nil, err
		}

		if err := owners.claim(name, c.KeyHash); err != nil {
			return nil, err
		}

		if c.Listener == "" {
			continue
		}

		l, ok := cfg.Listen[c.Listener]
		network, _ := l.Network()

		// The requests of a passed socket only count as a unix socket's.
		switch other, shared := listeners[c.Listener]; {
		case !ok:
			return nil, fmt.Errorf("clients.%s.listener: %q is not in listen", name, c.Listener)
		case network == "tcp":
			return nil, fmt.Errorf("clients.%s.listener: %q is no unix socket", name, c.Listener)
		case shared:
			return nil, fmt.Errorf("clients: %s and %s share a listener", min(name, other), max(name, other))
		}

		listeners[c.Listener] = name
	}

	return owners, nil
}

// validateClient checks a client on its own.
func (cfg *Config) validateClient(name string, c Client) error {
	switch {
	case !validHeaderValue(name):
		return fmt.Errorf("clients: invalid name %q", name)
	case (c.KeyHash == apikey.Hash{}) == (c.Listener == ""):
		return fmt.Errorf("clients.%s: must set exactly one of keyHash or listener", name)
	case !cfg.KnownPolicy(c.PolicyName):
		return fmt.Errorf("clients.%s.policy: unknown policy %q", name, c.PolicyName)
	}

	if err := c.validate(); err != nil {
		return fmt.Errorf("clients.%s.%w", name, err)
	}

	return nil
}

// loadClientCredentials adds the client of every credential, unless it is
// declared, claiming its key in owners. An invalid one is logged and skipped,
// since the config it outlives, such as by a renamed policy, must still start.
// A missing credentials directory holds no credentials.
func (cfg *Config) loadClientCredentials(owners keyOwners) error {
	names, err := secrets.CredentialNames()
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}

	for _, name := range names {
		client, ok := CredentialClient(name)
		if _, declared := cfg.Clients[client]; !ok || declared {
			continue
		}

		c, err := cfg.credentialClient(client, name)
		if err == nil {
			err = owners.claim(client, c.KeyHash)
		}

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

// credentialClient returns the valid client called name of the credential.
func (cfg *Config) credentialClient(name, credential string) (Client, error) {
	value, err := secrets.Credential(credential)
	if err != nil {
		return Client{}, err
	}

	c, err := ParseCredential([]byte(value))
	if err != nil {
		return Client{}, err
	}

	client := Client{KeyHash: c.KeyHash, PolicyName: c.Policy, ExpiresAt: c.ExpiresAt}

	return client, cfg.validateClient(name, client)
}
