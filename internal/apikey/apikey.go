// Package apikey issues the bearer tokens of clients, `llmhop_<secret><checksum>`,
// which llmhop stores only as their SHA-256 hash.
// The checksum is the CRC32 of the encoded secret, as in the tokens of GitHub,
// so that secret scanners discard random matches offline.
// A secret of 256 random bits needs no slow or salted hash,
// since guessing it is infeasible either way,
// and more bits would exceed the strength of the hash itself.
package apikey

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash/crc32"
)

// prefix starts every token, so that secret scanners recognize leaked ones.
const prefix = "llmhop_"

// encoding writes the secret in the alphabet of [rand.Text].
var encoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// Hash is the SHA-256 hash of a token, written as hex.
type Hash [sha256.Size]byte

// Generate returns a new token and its hash.
func Generate() (string, Hash) {
	var random [sha256.Size]byte
	rand.Read(random[:])
	secret := encoding.EncodeToString(random[:])
	token := prefix + secret + checksum(secret)

	return token, Of(token)
}

// checksum returns the CRC32 of secret in 7 characters of the encoding.
func checksum(secret string) string {
	sum := crc32.ChecksumIEEE([]byte(secret))

	return encoding.EncodeToString(binary.BigEndian.AppendUint32(nil, sum))
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
