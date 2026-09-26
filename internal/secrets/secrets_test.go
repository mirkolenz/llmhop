package secrets

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExpand(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(t *testing.T) string
		input   string
		want    string
		wantErr bool
	}{
		{
			name:  "literal",
			input: "no refs here",
			want:  "no refs here",
		},
		{
			name:  "empty",
			input: "",
			want:  "",
		},
		{
			name:  "dollar without reference",
			input: "a $ b $",
			want:  "a $ b $",
		},
		{
			name: "env braced",
			setup: func(t *testing.T) string {
				t.Setenv("LLMHOP_TEST_X", "secret")
				return "Bearer ${env:LLMHOP_TEST_X}"
			},
			want: "Bearer secret",
		},
		{
			name:    "bare name is rejected",
			input:   "pa$sword",
			wantErr: true,
		},
		{
			name:  "escaped reference",
			input: "a$${env:LLMHOP_TEST_X}",
			want:  "a${env:LLMHOP_TEST_X}",
		},
		{
			name:    "reference without scheme",
			input:   "${LLMHOP_TEST_X}",
			wantErr: true,
		},
		{
			name: "env missing",
			setup: func(t *testing.T) string {
				_ = os.Unsetenv("LLMHOP_TEST_MISSING")
				return "${env:LLMHOP_TEST_MISSING}"
			},
			wantErr: true,
		},
		{
			name: "multiple refs",
			setup: func(t *testing.T) string {
				t.Setenv("LLMHOP_TEST_A", "one")
				t.Setenv("LLMHOP_TEST_B", "two")
				return "${env:LLMHOP_TEST_A}-${env:LLMHOP_TEST_B}"
			},
			want: "one-two",
		},
		{
			name: "file absolute",
			setup: func(t *testing.T) string {
				return "${file:" + writeFile(t, "", "secret\n") + "}"
			},
			want: "secret",
		},
		{
			name: "cred by name",
			setup: func(t *testing.T) string {
				dir := t.TempDir()
				writeFile(t, dir, "v")
				t.Setenv("CREDENTIALS_DIRECTORY", dir)
				return "${cred:tok}"
			},
			want: "v",
		},
		{
			name: "cred without credentials directory",
			setup: func(t *testing.T) string {
				t.Setenv("CREDENTIALS_DIRECTORY", "")
				return "${cred:tok}"
			},
			wantErr: true,
		},
		{
			name: "cred rejects a path",
			setup: func(t *testing.T) string {
				t.Setenv("CREDENTIALS_DIRECTORY", t.TempDir())
				return "${cred:sub/tok}"
			},
			wantErr: true,
		},
		{
			name:    "file rejects a relative path",
			input:   "${file:tok}",
			wantErr: true,
		},
		{
			name: "file preserves internal whitespace, trims trailing",
			setup: func(t *testing.T) string {
				return "${file:" + writeFile(t, "", "a b\nc\r\n") + "}"
			},
			want: "a b\nc",
		},
		{
			name: "file trims only one trailing newline",
			setup: func(t *testing.T) string {
				return "${file:" + writeFile(t, "", "secret\n\n") + "}"
			},
			want: "secret\n",
		},
		{
			name: "file trims only one CRLF-terminated line",
			setup: func(t *testing.T) string {
				return "${file:" + writeFile(t, "", "secret\n\r\n") + "}"
			},
			want: "secret\n",
		},
		{
			name:    "file missing",
			input:   "${file:/does/not/exist/llmhop-test}",
			wantErr: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := c.input
			if c.setup != nil {
				in = c.setup(t)
			}
			got, err := Expand(in)
			if c.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestValidate(t *testing.T) {
	for _, in := range []string{"${file:tok}", "${cred:sub/tok}", "${env:}"} {
		if err := Validate(in); err == nil {
			t.Errorf("Validate(%q) accepted an invalid reference", in)
		}
	}

	if err := Validate("${env:LLMHOP_TEST_MISSING}"); err != nil {
		t.Errorf("Validate resolved a reference: %v", err)
	}
}

func writeFile(t *testing.T, dir, contents string) string {
	t.Helper()
	if dir == "" {
		dir = t.TempDir()
	}
	p := filepath.Join(dir, "tok")
	if err := os.WriteFile(p, []byte(contents), 0o400); err != nil {
		t.Fatal(err)
	}
	return p
}
