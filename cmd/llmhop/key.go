package main

import (
	"bytes"
	"cmp"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/secrets"
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

// store is a credential store of systemd, whose files are encrypted or not.
type store struct {
	dir       string
	encrypted bool
}

var (
	plainStore = store{"/etc/credstore", false}
	credstores = []store{plainStore, {"/etc/credstore.encrypted", true}}
)

// path returns the path of the credential of the client name.
func (s store) path(name string) string {
	return filepath.Join(s.dir, config.CredentialName(name))
}

// read reads the credential of the client name, failing with the path on an
// unreadable or invalid one.
func (s store) read(name string) (config.Credential, error) {
	path := s.path(name)

	var (
		data []byte
		err  error
	)

	if s.encrypted {
		data, err = exec.Command("systemd-creds", "decrypt", "--name="+filepath.Base(path), path, "-").Output()
	} else {
		data, err = os.ReadFile(path)
	}

	if err != nil {
		return config.Credential{}, fmt.Errorf("read %s: %w", path, err)
	}

	c, err := config.ParseCredential(data)
	if err != nil {
		return config.Credential{}, fmt.Errorf("parse %s: %w", path, err)
	}

	return c, nil
}

// write writes the credential of the client name atomically, failing with
// fs.ErrExist if it exists unless replace is set.
func (s store) write(name string, c config.Credential, replace bool) error {
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(s.dir, ".llmhop.")
	if err != nil {
		return err
	}

	defer func() { _ = os.Remove(tmp.Name()) }()

	path := s.path(name)

	if s.encrypted {
		cmd := exec.Command("systemd-creds", "encrypt", "--name="+filepath.Base(path), "-", "-")
		cmd.Stdin = bytes.NewReader(data)
		cmd.Stdout = tmp
		cmd.Stderr = os.Stderr
		err = cmd.Run()
	} else {
		_, err = tmp.Write(data)
	}

	if err := errors.Join(err, tmp.Close()); err != nil {
		return err
	}

	if replace {
		return os.Rename(tmp.Name(), path)
	}

	// A link, unlike a rename, never replaces an existing file.
	return os.Link(tmp.Name(), path)
}

// storedKeys returns the stores holding the key of each client that the
// config does not declare.
func storedKeys(cfg *config.Config) (map[string][]store, error) {
	stored := make(map[string][]store)

	for _, s := range credstores {
		files, err := secrets.CredentialFiles(s.dir)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, err
		}

		for _, file := range files {
			name, ok := config.CredentialClient(file)
			if _, declared := cfg.Clients[name]; ok && !declared {
				stored[name] = append(stored[name], s)
			}
		}
	}

	return stored, nil
}

// clientStores returns the stores holding the key of the client name, or
// fails.
func clientStores(cfg *config.Config, name string) ([]store, error) {
	stored, err := storedKeys(cfg)
	if err != nil {
		return nil, err
	}

	if len(stored[name]) == 0 {
		return nil, fmt.Errorf("client %q has no key", name)
	}

	return stored[name], nil
}

// rewrite changes the credential of the client name in every store holding
// it, reading every store and printing the token of a new key, if any,
// before writing any, then reloads the gateway.
func rewrite(cfg *config.Config, name, token string, change func(*config.Credential)) error {
	held, err := clientStores(cfg, name)
	if err != nil {
		return err
	}

	credentials := make([]config.Credential, len(held))

	for i, s := range held {
		if credentials[i], err = s.read(name); err != nil {
			return fmt.Errorf("%w, so it cannot be rewritten, revoke and create its key instead", err)
		}

		change(&credentials[i])
	}

	if token != "" {
		if err := printToken(token); err != nil {
			return err
		}
	}

	for i, s := range held {
		if err := s.write(name, credentials[i], true); err != nil {
			return err
		}
	}

	return reloadGateway()
}

// printToken prints the token of a new key, which must precede storing it,
// since the store holds only its hash.
func printToken(token string) error {
	if _, err := fmt.Println(token); err != nil {
		return fmt.Errorf("print token, storing nothing: %w", err)
	}

	return nil
}

// reloadGateway makes the gateway pick up the changed credentials.
func reloadGateway() error {
	cmd := exec.Command("systemctl", "try-reload-or-restart", unit)
	cmd.Stderr = os.Stderr
	err := cmd.Run()

	// llmhop reports a failed reload, which systemd lacks, through ERRNO=.
	status, statusErr := exec.Command("systemctl", "show", "--property=StatusErrno", "--value", unit).Output()

	if err != nil || statusErr != nil || strings.TrimSpace(string(status)) != "0" {
		return fmt.Errorf("the keys changed, but %s failed to pick them up, see `systemctl status %s`", unit, unit)
	}

	return nil
}
