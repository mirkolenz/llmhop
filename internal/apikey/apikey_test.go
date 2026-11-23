package apikey

import (
	"encoding/json/v2"
	"strings"
	"testing"
)

// A hash survives its text form, which rejects anything but its hex digits.
func TestHash(t *testing.T) {
	token, hash := Generate()
	if !strings.HasPrefix(token, prefix) || hash != Of(token) {
		t.Fatalf("Generate() = %q, %x", token, hash)
	}

	text, err := json.Marshal(hash)
	if err != nil {
		t.Fatal(err)
	}

	var got Hash
	if err := json.Unmarshal(text, &got); err != nil || got != hash {
		t.Errorf("round trip of %s = %x, %v", text, got, err)
	}

	for _, text := range []string{`"abc"`, `"` + strings.Repeat("g", 64) + `"`} {
		if err := json.Unmarshal([]byte(text), &got); err == nil {
			t.Errorf("Unmarshal(%s) succeeded", text)
		}
	}
}
