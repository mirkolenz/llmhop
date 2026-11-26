package main

import (
	"cmp"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"slices"
	"sync"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
)

// unit is the systemd unit of the gateway that the NixOS module sets up.
const unit = "llmhop.service"

// keyCmd manages the client credentials in the credential stores of systemd
// and applies a change by reloading or restarting the gateway.
type keyCmd struct {
	List     keyListCmd     `cmd:"" help:"List the clients with a stored key."`
	Create   keyCreateCmd   `cmd:"" help:"Store a key for a new client and print its token."`
	Update   keyUpdateCmd   `cmd:"" help:"Change the policy or expiry of a client, keeping its key."`
	Rotate   keyRotateCmd   `cmd:"" help:"Replace the key of a client and print its token."`
	Revoke   keyRevokeCmd   `cmd:"" help:"Delete the key of a client."`
	Generate keyGenerateCmd `cmd:"" help:"Print a new token and its credential, for a declared client or a credential file, storing nothing."`
}

type keyListCmd struct{}

func (keyListCmd) Run(cfg *config.Config) error {
	stored, err := storedKeys(cfg)
	if err != nil {
		return err
	}

	names := slices.Sorted(maps.Keys(stored))
	credentials := make([]config.Credential, len(names))
	errs := make([]error, len(names))

	// A decryption may take long, so all of them run at once.
	var wg sync.WaitGroup

	for i, name := range names {
		wg.Go(func() { credentials[i], errs[i] = stored[name][0].read(name) })
	}

	wg.Wait()

	rows := [][]string{{"CLIENT", "POLICY", "EXPIRES"}}

	// An unreadable credential is reported after the others are listed.
	for i, name := range names {
		if errs[i] != nil {
			rows = append(rows, []string{name, "?", "?"})

			continue
		}

		c := credentials[i]
		expires := "-"

		if !c.ExpiresAt.IsZero() {
			expires = c.ExpiresAt.Format(time.RFC3339)
		}

		rows = append(rows, []string{name, cmp.Or(c.Policy, "-"), expires})
	}

	fmt.Print(table(rows))

	return errors.Join(errs...)
}

// credentialFlags are the fields of a new credential besides its key.
type credentialFlags struct {
	Policy  string  `help:"Policy of the client."`
	Expires *moment `help:"Expiry, a date, an RFC 3339 time or a duration from now such as 30d."`
}

// generate returns a new token and its credential with the flags.
func (f credentialFlags) generate() (string, config.Credential) {
	token, hash := apikey.Generate()
	credential := config.Credential{KeyHash: hash, Policy: f.Policy}

	if f.Expires != nil {
		credential.ExpiresAt = f.Expires.resolve()
	}

	return token, credential
}

// clientArg names the client of a key command.
type clientArg struct {
	Name string `arg:"" help:"Name of the client."`
}

type keyCreateCmd struct {
	clientArg
	credentialFlags
}

func (c keyCreateCmd) Run(cfg *config.Config) error {
	switch _, declared := cfg.Clients[c.Name]; {
	case !cfg.ClientCredentials:
		return errors.New("the gateway does not import clientCredentials")
	case declared:
		return fmt.Errorf("client %q is declared in the config", c.Name)
	}

	if err := config.CheckCredentialClient(c.Name); err != nil {
		return fmt.Errorf("client %q: %w", c.Name, err)
	}

	stored, err := storedKeys(cfg)
	if err != nil {
		return err
	}

	if _, ok := stored[c.Name]; ok {
		return fmt.Errorf("client %q already has a key", c.Name)
	}

	if !cfg.KnownPolicy(c.Policy) {
		return unknownPolicy(c.Policy)
	}

	token, credential := c.generate()

	if err := printToken(token); err != nil {
		return err
	}

	if err := os.MkdirAll(plainStore.dir, 0o700); err != nil {
		return err
	}

	if err := plainStore.write(c.Name, credential, false); errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("client %q already has a key", c.Name)
	} else if err != nil {
		return err
	}

	return reloadGateway()
}

type keyUpdateCmd struct {
	clientArg
	Policy    *string `help:"Policy of the client, empty for none."`
	Expires   *moment `xor:"expiry" help:"Expiry, a date, an RFC 3339 time or a duration from now such as 30d."`
	NoExpires bool    `xor:"expiry" help:"Remove the expiry."`
}

func (c keyUpdateCmd) Run(cfg *config.Config) error {
	if c.Policy != nil && !cfg.KnownPolicy(*c.Policy) {
		return unknownPolicy(*c.Policy)
	}

	return rewrite(cfg, c.Name, "", func(credential *config.Credential) {
		if c.Policy != nil {
			credential.Policy = *c.Policy
		}

		switch {
		case c.NoExpires:
			credential.ExpiresAt = time.Time{}
		case c.Expires != nil:
			credential.ExpiresAt = c.Expires.resolve()
		}
	})
}

type keyRotateCmd struct{ clientArg }

func (c keyRotateCmd) Run(cfg *config.Config) error {
	token, hash := apikey.Generate()

	return rewrite(cfg, c.Name, token, func(credential *config.Credential) { credential.KeyHash = hash })
}

type keyRevokeCmd struct{ clientArg }

func (c keyRevokeCmd) Run(cfg *config.Config) error {
	held, err := clientStores(cfg, c.Name)
	if err != nil {
		return err
	}

	for _, s := range held {
		if err := os.Remove(s.path(c.Name)); err != nil {
			return err
		}
	}

	return reloadGateway()
}

type keyGenerateCmd struct{ credentialFlags }

func (c keyGenerateCmd) Run() error {
	token, credential := c.generate()

	out, err := json.Marshal(struct {
		Token      string            `json:"token"`
		Credential config.Credential `json:"credential"`
	}{token, credential})
	if err != nil {
		return err
	}

	fmt.Println(string(out))

	return nil
}

// rootConfig loads the config of the gateway for the key commands, failing
// outside systemd and unless run as root, who alone may access the
// credential stores. Without its secrets, its clients are only the declared
// ones.
func rootConfig(g *Globals) (*config.Config, error) {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return nil, errors.New("llmhop key manages the credentials of a systemd service, use `llmhop key generate` elsewhere")
	}

	if os.Geteuid() != 0 {
		return nil, errors.New("must be run as root")
	}

	return config.Load(g.Config, false)
}

func unknownPolicy(policy string) error {
	return fmt.Errorf("the gateway has no policy %q", policy)
}
