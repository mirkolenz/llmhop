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
// an empty credential to a backend. Without load it checks every reference
// without reading any secret and returns s verbatim, which catches every
// error except a secret that does not exist.
//
// It relies on os.Expand, which silently drops a malformed `${}` or unclosed
// `${`. What remains is literal text that fails authentication.
func Expand(s string, load bool) (string, error) {
	var errs []error

	out := os.Expand(s, func(key string) string {
		if key == "$" {
			return "$"
		}

		v, err := resolve(key, load)
		errs = append(errs, err)

		return v
	})

	if !load {
		out = s
	}

	return out, errors.Join(errs...)
}

// resolve checks the syntax of a `scheme:argument` reference and, if load is
// set, reads its secret.
func resolve(key string, load bool) (string, error) {
	scheme, arg, _ := strings.Cut(key, ":")

	var read func(string) (string, error)

	switch scheme {
	case "cred":
		if err := CheckCredentialName(arg); err != nil {
			return "", err
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

// CheckCredentialName rejects a credential name, or a prefix of one, that is
// not a plain file name inside the credentials directory.
func CheckCredentialName(name string) error {
	if !filepath.IsLocal(name) || filepath.Base(name) != name {
		return fmt.Errorf("invalid credential name %q", name)
	}

	return nil
}

// Credentials reads every systemd credential whose name starts with prefix,
// keyed by the rest of its name.
func Credentials(prefix string) (map[string]string, error) {
	dir, err := credentialsDir()
	if err != nil {
		return nil, fmt.Errorf("credentials %q*: %w", prefix, err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read credentials: %w", err)
	}

	creds := make(map[string]string)

	for _, entry := range entries {
		name, ok := strings.CutPrefix(entry.Name(), prefix)
		if !ok || name == "" || entry.IsDir() {
			continue
		}

		v, err := readFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}

		creds[name] = v
	}

	return creds, nil
}

// readCredential resolves the systemd credential called name. This is the same
// reference the NixOS module rewrites at eval time for the model servers, which
// receive a path because they read the file themselves; llmhop reads its own
// config, so here the reference expands to the credential's contents.
func readCredential(name string) (string, error) {
	dir, err := credentialsDir()
	if err != nil {
		return "", fmt.Errorf("credential %q: %w", name, err)
	}

	return readFile(filepath.Join(dir, name))
}

// credentialsDir is the directory systemd exposes the unit's credentials in.
func credentialsDir() (string, error) {
	dir := os.Getenv(credentialsDirectory)
	if dir == "" {
		return "", fmt.Errorf("$%s is not set", credentialsDirectory)
	}

	return dir, nil
}

// readFile reads a secret from an absolute path and trims trailing line
// terminators.
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, err)
	}

	return strings.TrimRight(string(data), "\r\n"), nil
}
