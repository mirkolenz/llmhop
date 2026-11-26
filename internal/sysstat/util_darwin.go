package sysstat

import (
	"encoding/binary"
	"math"

	"golang.org/x/sys/unix"
)

// sysctlNumber returns an unsigned integer of sysctl of 32 or 64 bits, or
// NaN.
func sysctlNumber(name string) float64 {
	raw, err := unix.SysctlRaw(name)

	switch {
	case err != nil:
		return math.NaN()
	case len(raw) == 4:
		return float64(binary.NativeEndian.Uint32(raw))
	case len(raw) == 8:
		return float64(binary.NativeEndian.Uint64(raw))
	}

	return math.NaN()
}
