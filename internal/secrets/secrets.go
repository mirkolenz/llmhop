// Package secrets resolves ${cred:NAME}, ${env:NAME}, ${file:PATH} and $NAME
// references inside config strings so credentials can stay out of the config file.
package secrets

import (
	"errors"
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
	return expand(s, resolve)
}

// Validate checks the reference syntax of s without resolving anything.
func Validate(s string) error {
	_, err := expand(s, func(string) (string, error) { return "", nil })
	return err
}

// expand is the one parser behind Expand and Validate. A `$` that starts
// neither `${KEY}` nor `$NAME` is kept literally.
func expand(s string, resolve func(key string) (string, error)) (string, error) {
	var out strings.Builder

	for {
		before, after, found := strings.Cut(s, "$")
		out.WriteString(before)

		if !found {
			return out.String(), nil
		}

		var key string

		if braced, ok := strings.CutPrefix(after, "{"); ok {
			name, rest, closed := strings.Cut(braced, "}")
			if !closed || name == "" {
				return "", errors.New("malformed secret reference")
			}

			key, s = name, rest
		} else {
			n := strings.IndexFunc(after, func(r rune) bool {
				return !(r == '_' || r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z')
			})
			if n < 0 {
				n = len(after)
			}

			if n == 0 {
				out.WriteByte('$')
				s = after

				continue
			}

			key, s = after[:n], after[n:]
		}

		v, err := resolve(key)
		if err != nil {
			return "", err
		}

		out.WriteString(v)
	}
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

	return strings.TrimSuffix(strings.TrimSuffix(string(data), "\r\n"), "\n"), nil
}
