// Package secrets resolves ${cred:NAME}, ${env:NAME} and ${file:PATH}
// references inside config strings so credentials can stay out of the config file.
// `$$` stands for a literal `$`.
package secrets

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// credentialsDirectory is where systemd exposes the unit's credentials.
const credentialsDirectory = "CREDENTIALS_DIRECTORY"

// Expand resolves every secret reference inside s. Unresolved references
// are errors so misconfiguration fails loudly at startup instead of leaking
// an empty credential to a backend.
func Expand(s string) (string, error) {
	return expand(s, true)
}

// Validate checks every reference of s without reading any secret, so it
// catches everything Expand would except secrets that do not exist.
func Validate(s string) error {
	_, err := expand(s, false)
	return err
}

// expand relies on os.Expand, which silently drops a malformed `${}` or
// unclosed `${`. What remains is literal text that fails authentication.
func expand(s string, load bool) (string, error) {
	var errs []error

	out := os.Expand(s, func(key string) string {
		if key == "$" {
			return "$"
		}

		v, err := resolve(key, load)
		errs = append(errs, err)

		return v
	})

	return out, errors.Join(errs...)
}

// resolve checks the syntax of a `scheme:argument` reference and, if load is
// set, reads its secret.
func resolve(key string, load bool) (string, error) {
	scheme, arg, _ := strings.Cut(key, ":")

	var read func(string) (string, error)

	switch scheme {
	case "cred":
		if !filepath.IsLocal(arg) || filepath.Base(arg) != arg {
			return "", fmt.Errorf("invalid credential name %q", arg)
		}

		read = readCredential
	case "env":
		if arg == "" {
			return "", fmt.Errorf("invalid env var name %q", arg)
		}

		read = lookupEnv
	case "file":
		if !filepath.IsAbs(arg) {
			return "", fmt.Errorf("secret file %q must be an absolute path", arg)
		}

		read = readFile
	default:
		return "", fmt.Errorf("%q is not a cred:, env: or file: reference, write $$ for a literal $", key)
	}

	if !load {
		return "", nil
	}

	return read(arg)
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
	dir := os.Getenv(credentialsDirectory)
	if dir == "" {
		return "", fmt.Errorf("credential %q requested but $%s is not set", name, credentialsDirectory)
	}
	return readFile(filepath.Join(dir, name))
}

// readFile reads a secret from an absolute path and trims a single trailing
// line terminator.
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, err)
	}

	value, hasNewline := strings.CutSuffix(string(data), "\n")
	if hasNewline {
		value = strings.TrimSuffix(value, "\r")
	}

	return value, nil
}
