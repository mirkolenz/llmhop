package sysstat

import (
	"encoding/binary"
	"math"

	"golang.org/x/sys/unix"
)

// readHost returns the state of the host from sysctl, where the available
// memory is the free, speculative, purgeable and file-backed pages, as
// Activity Monitor counts it, and the CPU time stays unknown.
func readHost() *Host {
	cpus := sysctlNumber("hw.logicalcpu")
	if math.IsNaN(cpus) {
		return nil
	}

	h := newHost()
	h.CPUs = int(cpus)
	h.MemTotal = sysctlNumber("hw.memsize")

	pages := 0.0

	for _, name := range []string{"vm.page_free_count", "vm.page_speculative_count", "vm.page_purgeable_count", "vm.page_pageable_external_count"} {
		pages += sysctlNumber(name)
	}

	h.MemAvailable = pages * sysctlNumber("vm.pagesize")

	// struct loadavg holds three fixed-point loads and their scale.
	if raw, err := unix.SysctlRaw("vm.loadavg"); err == nil && len(raw) >= 24 {
		scale := float64(binary.NativeEndian.Uint64(raw[16:]))

		for i := range h.Load {
			h.Load[i] = float64(binary.NativeEndian.Uint32(raw[4*i:])) / scale
		}
	}

	// struct xsw_usage starts with the total, available and used bytes.
	if raw, err := unix.SysctlRaw("vm.swapusage"); err == nil && len(raw) >= 24 {
		h.SwapTotal = float64(binary.NativeEndian.Uint64(raw))
		h.SwapFree = float64(binary.NativeEndian.Uint64(raw[8:]))
	}

	return h
}
