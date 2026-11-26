package main

import (
	"bytes"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/secrets"
)

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
