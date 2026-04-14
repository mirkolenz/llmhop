// Package secrets resolves ${env:NAME}, ${file:PATH} and $NAME references
// inside config strings so credentials can stay out of the config file.
package secrets

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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

// readFile reads a credential from disk. Relative paths are resolved
// against systemd's $CREDENTIALS_DIRECTORY when set, matching LoadCredential=.
func readFile(path string) (string, error) {
	if !filepath.IsAbs(path) {
		if dir := os.Getenv("CREDENTIALS_DIRECTORY"); dir != "" {
			path = filepath.Join(dir, path)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, err)
	}
	return strings.TrimRight(string(data), "\r\n"), nil
}
