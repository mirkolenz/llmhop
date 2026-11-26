package sysstat

import (
	"os"
	"strings"
)

// readHost returns the state of the host from procfs, or nil without it.
func readHost() *Host {
	stat, err := os.ReadFile("/proc/stat")
	if err != nil {
		return nil
	}

	h := newHost()

	for line := range strings.Lines(string(stat)) {
		// Other lines, such as that of the interrupts, may be long.
		if !strings.HasPrefix(line, "cpu") {
			continue
		}

		fields := strings.Fields(line)

		if fields[0] != "cpu" || len(fields) < 9 {
			h.CPUs++

			continue
		}

		// user, nice, system, idle, iowait, irq, softirq and steal, where
		// guest time is part of user time already.
		for i, f := range fields[1:9] {
			v := number(f)
			h.Total += v

			if i != 3 && i != 4 {
				h.Busy += v
			}
		}
	}

	for i, f := range strings.Fields(readText("/proc/loadavg")) {
		if i < len(h.Load) {
			h.Load[i] = number(f)
		}
	}

	meminfo, _ := os.ReadFile("/proc/meminfo")
	fields := map[string]*float64{"MemTotal:": &h.MemTotal, "MemAvailable:": &h.MemAvailable, "SwapTotal:": &h.SwapTotal, "SwapFree:": &h.SwapFree}

	for line := range strings.Lines(string(meminfo)) {
		// Such as `MemTotal:  16303420 kB`.
		if f := strings.Fields(line); len(f) == 3 && fields[f[0]] != nil {
			*fields[f[0]] = number(f[1]) * 1024
		}
	}

	return h
}
