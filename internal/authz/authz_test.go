package authz

import "testing"

func TestCheckBearer(t *testing.T) {
	tokens := [][]byte{[]byte("alpha"), []byte("beta")}
	cases := []struct {
		name   string
		header string
		tokens [][]byte
		want   bool
	}{
		{"valid first token", "Bearer alpha", tokens, true},
		{"valid second token", "Bearer beta", tokens, true},
		{"unknown token", "Bearer gamma", tokens, false},
		{"missing scheme", "alpha", tokens, false},
		{"wrong scheme", "Basic alpha", tokens, false},
		{"empty header", "", tokens, false},
		{"bearer without token", "Bearer ", tokens, false},
		{"case-sensitive scheme", "bearer alpha", tokens, false},
		{"prefix-only match is not accepted", "Bearer alph", tokens, false},
		{"extra whitespace is not trimmed", "Bearer alpha ", tokens, false},
		{"no configured tokens", "Bearer anything", nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := CheckBearer(c.header, c.tokens); got != c.want {
				t.Fatalf("CheckBearer(%q) = %v, want %v", c.header, got, c.want)
			}
		})
	}
}
