//go:build !linux

package systemd

// monotonicUsec is unavailable outside Linux, where systemd does not run.
func monotonicUsec() uint64 {
	return 0
}
