// Package secrets resolves ${cred:NAME} and ${env:NAME} references inside
// config strings so secrets can stay out of the config file.
// `$$` stands for a literal `$`.
package secrets

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// credentialsDirectory names the directory of the credentials, where
// systemd exposes those of the unit and the image sets `/run/secrets`, the
// secrets of Docker, Compose and Podman.
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
			return "", errors.New("empty env var name")
		}

		read = lookupEnv
	default:
		return "", fmt.Errorf("%q is not a cred: or env: reference, write $$ for a literal $", key)
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
// systemd accepts that llmhop and the NixOS module share: an ASCII letter,
// digit or `_`, followed by those, `.` and `-`.
func CheckCredentialName(name string) error {
	valid := func(r rune) bool {
		return 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9' || strings.ContainsRune("_.-", r)
	}

	if name == "" || len(name) > maxCredentialName || name[0] == '.' || name[0] == '-' || strings.ContainsFunc(name, func(r rune) bool { return !valid(r) }) {
		return fmt.Errorf("invalid credential name %q", name)
	}

	return nil
}

// CredentialNames lists the credentials.
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

// Credential reads the credential called name without the trailing line
// terminators that files and pipes usually end with.
func Credential(name string) (string, error) {
	dir, err := credentialsDir()
	if err != nil {
		return "", fmt.Errorf("credential %q: %w", name, err)
	}

	// A root keeps a name from escaping the directory.
	root, err := os.OpenRoot(dir)
	if err != nil {
		return "", fmt.Errorf("credentials: %w", err)
	}
	defer func() { _ = root.Close() }()

	data, err := root.ReadFile(name)
	if err != nil {
		return "", fmt.Errorf("read credential: %w", err)
	}

	return strings.TrimRight(string(data), "\r\n"), nil
}

// credentialsDir is the directory of the credentials.
func credentialsDir() (string, error) {
	dir := os.Getenv(credentialsDirectory)
	if dir == "" {
		return "", fmt.Errorf("$%s is not set", credentialsDirectory)
	}

	return dir, nil
}
