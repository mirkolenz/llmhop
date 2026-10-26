package secrets

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExpand(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CREDENTIALS_DIRECTORY", dir)
	t.Setenv("LLMHOP_TEST_X", "secret")
	_ = os.Unsetenv("LLMHOP_TEST_MISSING")

	file := func(name, contents string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(contents), 0o400); err != nil {
			t.Fatal(err)
		}
		return "${file:" + p + "}"
	}

	cases := []struct {
		in      string
		load    bool
		want    string
		wantErr bool
	}{
		{"Bearer ${env:LLMHOP_TEST_X}", true, "Bearer secret", false},
		{"a$${env:LLMHOP_TEST_X}", true, "a${env:LLMHOP_TEST_X}", false},
		{"pa$sword", true, "", true},
		{"${LLMHOP_TEST_X}", true, "", true},
		{"${env:LLMHOP_TEST_MISSING}", true, "", true},
		{"${env:LLMHOP_TEST_MISSING}", false, "${env:LLMHOP_TEST_MISSING}", false},
		{"${env:}", false, "", true},
		{"${file:tok}", false, "", true},
		{"${cred:sub/tok}", false, "", true},
		{file("tok", "a b\nc\r\n"), true, "a b\nc", false},
		{"${cred:tok}", true, "a b\nc", false},
		{file("lines", "secret\n\r\n"), true, "secret", false},
		{"${file:/does/not/exist/llmhop-test}", true, "", true},
	}

	for _, c := range cases {
		if got, err := Expand(c.in, c.load); got != c.want && !c.wantErr || (err != nil) != c.wantErr {
			t.Errorf("Expand(%q, %v) = %q, %v", c.in, c.load, got, err)
		}
	}

	t.Setenv("CREDENTIALS_DIRECTORY", "")

	if _, err := Expand("${cred:tok}", true); err == nil {
		t.Error("resolved a credential without $CREDENTIALS_DIRECTORY")
	}
}
