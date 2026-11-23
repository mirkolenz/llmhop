// Package apikey issues the bearer tokens of clients, `llmhop_<secret>`,
// which llmhop stores only as their SHA-256 hash.
// A secret of 130 random bits needs no slow or salted hash,
// since guessing it is infeasible either way.
package apikey

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// prefix starts every token, so that secret scanners recognize leaked ones.
const prefix = "llmhop_"

// Hash is the SHA-256 hash of a token, written as hex.
type Hash [sha256.Size]byte

// Generate returns a new token and its hash.
func Generate() (string, Hash) {
	token := prefix + rand.Text()

	return token, Of(token)
}

// Of returns the hash of token.
func Of(token string) Hash {
	return sha256.Sum256([]byte(token))
}

// MarshalText writes h as lowercase hex.
func (h Hash) MarshalText() ([]byte, error) {
	return hex.AppendEncode(nil, h[:]), nil
}

// UnmarshalText reads h from hex.
func (h *Hash) UnmarshalText(text []byte) error {
	if n := hex.EncodedLen(len(h)); len(text) != n {
		return fmt.Errorf("must be %d hex digits", n)
	}

	_, err := hex.Decode(h[:], text)

	return err
}
