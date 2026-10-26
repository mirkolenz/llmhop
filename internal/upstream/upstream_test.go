package upstream

import "testing"

func TestParse(t *testing.T) {
	for _, raw := range []string{"http://127.0.0.1:8000", "https://api.openai.com/v1", "unix:///run/x.sock"} {
		if _, err := Parse(raw); err != nil {
			t.Errorf("%s: %v", raw, err)
		}
	}

	for _, raw := range []string{"127.0.0.1:8000", "http:///path", "http://user:pass@example.com", "http://example.com/path#fragment", "unix://host/x.sock", "unix://relative.sock", "ftp://x"} {
		if _, err := Parse(raw); err == nil {
			t.Errorf("%s: expected error", raw)
		}
	}
}
