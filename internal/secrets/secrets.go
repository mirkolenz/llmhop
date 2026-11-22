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

		read = Credential
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

// maxCredentialName is the longest credential name systemd accepts.
const maxCredentialName = 255

// CheckCredentialName rejects a credential name outside the subset of those
// systemd accepts that llmhop, llmhopctl and the NixOS module share: an
// ASCII letter, digit or `_`, followed by those, `.` and `-`.
func CheckCredentialName(name string) error {
	valid := func(r rune) bool {
		return 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9' || strings.ContainsRune("_.-", r)
	}

	if name == "" || len(name) > maxCredentialName || name[0] == '.' || name[0] == '-' || strings.ContainsFunc(name, func(r rune) bool { return !valid(r) }) {
		return fmt.Errorf("invalid credential name %q", name)
	}

	return nil
}

// CredentialNames lists the systemd credentials of the unit.
func CredentialNames() ([]string, error) {
	dir, err := credentialsDir()
	if err != nil {
		return nil, fmt.Errorf("credentials: %w", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read credentials: %w", err)
	}

	var names []string

	for _, entry := range entries {
		if !entry.IsDir() {
			names = append(names, entry.Name())
		}
	}

	return names, nil
}

// Credential reads the systemd credential called name. This is the same
// reference the NixOS module rewrites at eval time for the model servers, which
// receive a path because they read the file themselves. llmhop reads its own
// config, so here the reference expands to the credential's contents.
func Credential(name string) (string, error) {
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

// readFile reads a secret from an absolute path, without the trailing line
// terminators that files and pipes usually end with.
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read secret file %q: %w", path, err)
	}

	return strings.TrimRight(string(data), "\r\n"), nil
}
