// Package sysstat reads the state of the CPUs, memory, filesystems and
// network interfaces of the host through gopsutil, and of its GPUs from
// nvidia-smi and sysfs on Linux and from the I/O registry on macOS.
package sysstat

import (
	"context"
	"math"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
)

// Sampler samples the host and its GPUs, keeping the state that some
// sources need between samples and what never changes.
type Sampler struct {
	gpus *gpuSource
	cpus int
}

// NewSampler starts sampling about every interval until ctx is done.
func NewSampler(ctx context.Context, interval time.Duration) *Sampler {
	cpus, _ := cpu.CountsWithContext(ctx, true)

	return &Sampler{newGPUSource(ctx, interval), cpus}
}

// Host returns the state of the host, or nil where nothing reports it.
func (s *Sampler) Host(ctx context.Context) *Host {
	return readHost(ctx, s.cpus)
}

// GPUs returns the latest state of the GPUs.
func (s *Sampler) GPUs(ctx context.Context) []GPU {
	return s.gpus.read(ctx)
}

// GPU is the state of a graphics card, NaN where it reports nothing.
type GPU struct {
	ID, Name string
	// Busy is the busy share, MemUsed and MemTotal are in bytes, Temp in
	// degrees Celsius, Power and PowerCap in watts and Clock in MHz.
	Busy, MemUsed, MemTotal, Temp, Power, PowerCap, Clock float64
	// Limits are the reasons that slow down its clock.
	Limits    []string
	Processes []Process
}

// newGPU returns a card that reports nothing yet.
func newGPU(id, name string) GPU {
	nan := math.NaN()

	return GPU{ID: id, Name: name, Busy: nan, MemUsed: nan, MemTotal: nan, Temp: nan, Power: nan, PowerCap: nan, Clock: nan}
}

// Process is the memory of a card that a systemd unit or a process
// uses.
type Process struct {
	Owner string
	Mem   float64
}

// Host is the state of the CPUs, memory, filesystems and network
// interfaces of the host, NaN where it reports nothing.
type Host struct {
	CPUs int
	// Busy and Total count the seconds of all CPUs.
	Busy, Total float64
	Load        [3]float64
	// The memory and swap are in bytes.
	MemTotal, MemAvailable, SwapTotal, SwapFree float64
	Disks                                       []Disk
	Interfaces                                  []Interface
}

// Disk is a mounted filesystem and the device it is on, NaN where it
// reports nothing.
type Disk struct {
	Mount string
	// Size and Free count bytes, Free those that unprivileged users may
	// still write.
	Size, Free float64
	// Read and Written count the bytes of the device, Busy the seconds it
	// was busy, on macOS those of its reads and writes, which may overlap.
	Read, Written, Busy float64
}

// newDisk returns a filesystem that reports nothing yet.
func newDisk(mount string) Disk {
	nan := math.NaN()

	return Disk{Mount: mount, Size: nan, Free: nan, Read: nan, Written: nan, Busy: nan}
}

// Interface is a network interface and the bytes it received and sent.
type Interface struct {
	Name           string
	Received, Sent float64
}

// newHost returns a host that reports nothing yet.
func newHost() *Host {
	nan := math.NaN()

	return &Host{Load: [3]float64{nan, nan, nan}, MemTotal: nan, MemAvailable: nan, SwapTotal: nan, SwapFree: nan}
}

// CPU returns the busy share of all CPUs since before, or NaN.
func (h Host) CPU(before Host) float64 {
	if dt := h.Total - before.Total; dt > 0 {
		return (h.Busy - before.Busy) / dt
	}

	return math.NaN()
}

// LoadShare returns the load of the latest minute per CPU.
func (h Host) LoadShare() float64 {
	return h.Load[0] / float64(h.CPUs)
}

// MemoryShare returns the share of the memory in use.
func (h Host) MemoryShare() float64 {
	return 1 - h.MemAvailable/h.MemTotal
}

// SwapShare returns the share of the swap in use.
func (h Host) SwapShare() float64 {
	return 1 - h.SwapFree/h.SwapTotal
}
