package sysstat

import (
	"cmp"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// gpuSource reads the cards of NVIDIA through nvidia-smi, since its
// proprietary driver reports nothing in sysfs, and those of AMD and Intel
// through the sysfs of their kernel drivers.
type gpuSource struct {
	nvidia *nvidiaStream
	// counters holds the latest counters of the cards that report their
	// busy share and power only through them, by card.
	counters map[string]drmCounters
}

func newGPUSource(ctx context.Context, interval time.Duration) *gpuSource {
	return &gpuSource{nvidia: startNvidia(ctx, interval)}
}

func (s *gpuSource) read(ctx context.Context) []GPU {
	return append(s.nvidia.read(ctx), s.drmGPUs()...)
}

// drm is where the kernel lists the cards of its DRM drivers.
const drm = "/sys/class/drm"

// drmVendors names the PCI vendors whose cards sysfs reports.
var drmVendors = map[string]string{"0x1002": "AMD", "0x8086": "Intel"}

// drmCounters is when a card was read, the seconds it idled and the joules
// it used until then.
type drmCounters struct {
	at           time.Time
	idle, energy float64
}

// drmGPUs reads the cards of amdgpu, i915 and xe from sysfs, where amdgpu
// reports its busy share and power, and i915 and xe only the time they
// idle and the energy they use, whose increase gives them. None of them
// reports its users without privileges.
func (s *gpuSource) drmGPUs() []GPU {
	entries, err := os.ReadDir(drm)
	if err != nil {
		return nil
	}

	var out []GPU

	counters := make(map[string]drmCounters)

	for _, e := range entries {
		// Connectors such as card0-DP-1 share the prefix.
		n, ok := strings.CutPrefix(e.Name(), "card")
		if _, err := strconv.Atoi(n); !ok || err != nil {
			continue
		}

		card := filepath.Join(drm, e.Name())
		dev := filepath.Join(card, "device")

		vendor, ok := drmVendors[readText(filepath.Join(dev, "vendor"))]
		if !ok {
			continue
		}

		hwmon := filepath.Join(dev, "hwmon", firstEntry(filepath.Join(dev, "hwmon")))
		g := newGPU(e.Name(), cmp.Or(readText(filepath.Join(dev, "product_name")), vendor+" "+readText(filepath.Join(dev, "device"))))
		g.Busy = readNumber(0.01, dev, "gpu_busy_percent")
		g.MemUsed = readNumber(1, dev, "mem_info_vram_used")
		g.MemTotal = readNumber(1, dev, "mem_info_vram_total")
		g.Temp = readNumber(0.001, hwmon, "temp1_input", "temp2_input", "temp3_input")
		g.Power = readNumber(1e-6, hwmon, "power1_average", "power1_input")
		g.PowerCap = readNumber(1e-6, hwmon, "power1_cap", "power1_max")
		g.Clock = firstNumber(
			readNumber(1e-6, hwmon, "freq1_input"),
			readNumber(1, card, "gt_act_freq_mhz"),
			readNumber(1, dev, "tile0/gt0/freq0/act_freq"),
		)

		now := drmCounters{
			at:     time.Now(),
			energy: readNumber(1e-6, hwmon, "energy1_input"),
			idle: firstNumber(
				readNumber(0.001, dev, "tile0/gt0/gtidle/idle_residency_ms"),
				readNumber(0.001, card, "gt/gt0/rc6_residency_ms", "power/rc6_residency_ms"),
			),
		}
		counters[g.ID] = now

		// The counters are read one after another, so their increase may
		// exceed the time between two reads a little.
		if before, ok := s.counters[g.ID]; ok {
			seconds := now.at.Sub(before.at).Seconds()
			g.Busy = firstNumber(g.Busy, min(max(1-(now.idle-before.idle)/seconds, 0), 1))
			g.Power = firstNumber(g.Power, max((now.energy-before.energy)/seconds, 0))
		}

		out = append(out, g)
	}

	s.counters = counters

	return out
}
