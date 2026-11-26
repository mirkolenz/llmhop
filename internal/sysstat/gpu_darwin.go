package sysstat

import (
	"context"
	"math"
	"os/exec"
	"strconv"
	"time"

	"golang.org/x/sys/unix"
	"howett.net/plist"
)

// gpuSource reads the GPUs of Apple silicon from the I/O registry, whose
// statistics report their busy share and the unified memory they use, of
// the memory of the host.
type gpuSource struct {
	memory float64
}

func newGPUSource(context.Context, time.Duration) *gpuSource {
	memory, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return &gpuSource{math.NaN()}
	}

	return &gpuSource{float64(memory)}
}

// accelerator is a GPU in the I/O registry, nil where it reports nothing.
type accelerator struct {
	Model string `plist:"model"`
	Stats struct {
		Busy   *uint64 `plist:"Device Utilization %"`
		Memory *uint64 `plist:"In use system memory"`
	} `plist:"PerformanceStatistics"`
}

func (s *gpuSource) read(ctx context.Context) []GPU {
	out, err := exec.CommandContext(ctx, "ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator", "-a").Output()
	if err != nil {
		return nil
	}

	var accelerators []accelerator

	if _, err := plist.Unmarshal(out, &accelerators); err != nil {
		return nil
	}

	var gpus []GPU

	for i, a := range accelerators {
		g := newGPU(strconv.Itoa(i), a.Model)
		g.Busy = known(a.Stats.Busy) / 100
		g.MemUsed = known(a.Stats.Memory)
		g.MemTotal = s.memory
		gpus = append(gpus, g)
	}

	return gpus
}

// known returns v, or NaN if nil.
func known(v *uint64) float64 {
	if v == nil {
		return math.NaN()
	}

	return float64(*v)
}
