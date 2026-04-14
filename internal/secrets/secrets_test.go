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
			name: "env braced",
			setup: func(t *testing.T) string {
				t.Setenv("LLMHOP_TEST_X", "secret")
				return "Bearer ${env:LLMHOP_TEST_X}"
			},
			want: "Bearer secret",
		},
		{
			name: "env bare shorthand",
			setup: func(t *testing.T) string {
				t.Setenv("LLMHOP_TEST_X", "secret")
				return "$LLMHOP_TEST_X"
			},
			want: "secret",
		},
		{
			name: "env missing",
			setup: func(t *testing.T) string {
				os.Unsetenv("LLMHOP_TEST_MISSING")
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
			name: "file via CREDENTIALS_DIRECTORY",
			setup: func(t *testing.T) string {
				dir := t.TempDir()
				writeFile(t, dir, "v")
				t.Setenv("CREDENTIALS_DIRECTORY", dir)
				return "${file:tok}"
			},
			want: "v",
		},
		{
			name: "file preserves internal whitespace, trims trailing",
			setup: func(t *testing.T) string {
				return "${file:" + writeFile(t, "", "a b\nc\r\n") + "}"
			},
			want: "a b\nc",
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
