// Package secrets resolves ${cred:NAME}, ${env:NAME}, ${file:PATH} and $NAME
// references inside config strings so credentials can stay out of the config file.
package secrets

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// credentialsDirectory is where systemd exposes the unit's LoadCredential= set.
const credentialsDirectory = "CREDENTIALS_DIRECTORY"

// Expand resolves every secret reference inside s. Unresolved references
// return the first error encountered so misconfiguration fails loudly at
// startup instead of leaking an empty credential to a backend.
func Expand(s string) (string, error) {
	var firstErr error
	out := os.Expand(s, func(key string) string {
		v, err := resolve(key)
		if err != nil && firstErr == nil {
			firstErr = err
		}
		return v
	})
	return out, firstErr
}

func resolve(key string) (string, error) {
	if name, ok := strings.CutPrefix(key, "cred:"); ok {
		return readCredential(name)
	}
	if name, ok := strings.CutPrefix(key, "env:"); ok {
		return lookupEnv(name)
	}
	if path, ok := strings.CutPrefix(key, "file:"); ok {
		return readFile(path)
	}
	return lookupEnv(key)
}

func lookupEnv(name string) (string, error) {
	v, present := os.LookupEnv(name)
	if !present {
		return "", fmt.Errorf("env var %q not set", name)
	}
	return v, nil
}

// readCredential resolves the systemd credential called name. This is the same
// reference the NixOS module rewrites at eval time for the model servers, which
// receive a path because they read the file themselves; llmhop reads its own
// config, so here the reference expands to the credential's contents.
func readCredential(name string) (string, error) {
	if name == "" || strings.ContainsRune(name, filepath.Separator) {
		return "", fmt.Errorf("invalid credential name %q", name)
	}
	dir := os.Getenv(credentialsDirectory)
	if dir == "" {
		return "", fmt.Errorf("credential %q requested but $%s is not set", name, credentialsDirectory)
	}
	return readFile(filepath.Join(dir, name))
}

// readFile reads a credential from an absolute path. Credentials granted through
// systemd are addressed by name with ${cred:NAME} instead, so this stays a plain
// path reference for files llmhop is pointed at directly.
func readFile(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("secret file %q must be an absolute path", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, err)
	}
	return strings.TrimRight(string(data), "\r\n"), nil
}
