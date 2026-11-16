//go:build linux

package systemd

import (
	"syscall"
	"unsafe"
)

// clockMonotonic is CLOCK_MONOTONIC, which systemd timestamps with.
const clockMonotonic = 1

// monotonicUsec reads CLOCK_MONOTONIC in microseconds, which cannot fail. The
// time package only exposes the clock relative to process start.
func monotonicUsec() uint64 {
	var ts syscall.Timespec

	_, _, _ = syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockMonotonic, uintptr(unsafe.Pointer(&ts)), 0)

	return uint64(ts.Nano()) / 1_000
}
