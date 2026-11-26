package sysstat

import (
	"context"
	"math"
	"os/exec"
	"strconv"
	"time"
)

// gpuSource reads the GPUs of Apple silicon from the I/O registry, whose
// statistics report their busy share and the unified memory they use.
type gpuSource struct{}

func newGPUSource(context.Context, time.Duration) *gpuSource {
	return &gpuSource{}
}

func (*gpuSource) read(ctx context.Context) []GPU {
	out, err := exec.CommandContext(ctx, "ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator", "-a").Output()
	if err != nil {
		return nil
	}

	registry, err := decodePlist(out)
	if err != nil {
		return nil
	}

	accelerators, _ := registry.([]any)
	memory := sysctlNumber("hw.memsize")

	var gpus []GPU

	for i, a := range accelerators {
		props, _ := a.(map[string]any)
		stats, _ := props["PerformanceStatistics"].(map[string]any)
		name, _ := props["model"].(string)
		g := newGPU(strconv.Itoa(i), name)
		g.Busy = plistNumber(stats, "Device Utilization %") / 100
		g.MemUsed = plistNumber(stats, "In use system memory")
		g.MemTotal = memory
		gpus = append(gpus, g)
	}

	return gpus
}

// plistNumber returns the number of a key of dict, or NaN.
func plistNumber(dict map[string]any, key string) float64 {
	if v, ok := dict[key].(float64); ok {
		return v
	}

	return math.NaN()
}
