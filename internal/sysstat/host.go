package sysstat

import (
	"context"
	"net"
	"path/filepath"
	"slices"
	"strings"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	psnet "github.com/shirou/gopsutil/v4/net"
)

// readHost returns the state of the host with cpus CPUs, or nil where
// nothing reports its CPU time.
func readHost(ctx context.Context, cpus int) *Host {
	times, err := cpu.TimesWithContext(ctx, false)
	if err != nil || len(times) == 0 {
		return nil
	}

	h := newHost()
	h.CPUs = cpus

	// Guest time is part of user time already.
	t := times[0]
	h.Busy = t.User + t.Nice + t.System + t.Irq + t.Softirq + t.Steal
	h.Total = h.Busy + t.Idle + t.Iowait

	if l, err := load.AvgWithContext(ctx); err == nil {
		h.Load = [3]float64{l.Load1, l.Load5, l.Load15}
	}

	if m, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		h.MemTotal, h.MemAvailable = float64(m.Total), float64(m.Available)
	}

	if s, err := mem.SwapMemoryWithContext(ctx); err == nil {
		h.SwapTotal, h.SwapFree = float64(s.Total), float64(s.Free)
	}

	h.Disks = readDisks(ctx)
	h.Interfaces = readInterfaces(ctx)

	return h
}

// readDisks returns the filesystems mounted from devices, each device by
// its first mount, such as of btrfs subvolumes, without the system volumes
// that macOS hides.
func readDisks(ctx context.Context) []Disk {
	partitions, err := disk.PartitionsWithContext(ctx, false)
	if err != nil {
		return nil
	}

	var (
		out     []Disk
		devices []string
	)

	seen := make(map[string]bool)

	for _, p := range partitions {
		if !strings.HasPrefix(p.Device, "/dev/") || slices.Contains(p.Opts, "nobrowse") || seen[p.Device] {
			continue
		}

		seen[p.Device] = true
		d := newDisk(p.Mountpoint)

		if u, err := disk.UsageWithContext(ctx, p.Mountpoint); err == nil {
			d.Size, d.Free = float64(u.Total), float64(u.Free)
		}

		out = append(out, d)
		devices = append(devices, filepath.Base(p.Device))
	}

	// Without names, it reads every device, such as loops and partitions.
	if len(devices) == 0 {
		return out
	}

	counters, _ := disk.IOCountersWithContext(ctx, slices.Clone(devices)...)

	for i, dev := range devices {
		if c, ok := counters[dev]; ok {
			out[i].Read, out[i].Written, out[i].Busy = float64(c.ReadBytes), float64(c.WriteBytes), float64(c.IoTime)/1000
		}
	}

	return out
}

// readInterfaces returns the network interfaces that are up with an
// address beyond their link, those of the networks and tunnels of the host,
// unlike the loopback, the members of bridges and the links of containers.
func readInterfaces(ctx context.Context) []Interface {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}

	all, _ := psnet.IOCountersWithContext(ctx, true)
	counters := make(map[string]psnet.IOCountersStat, len(all))

	for _, c := range all {
		counters[c.Name] = c
	}

	var out []Interface

	for _, i := range interfaces {
		c, ok := counters[i.Name]

		if ok && i.Flags&net.FlagUp != 0 && routable(i) {
			out = append(out, Interface{Name: i.Name, Received: float64(c.BytesRecv), Sent: float64(c.BytesSent)})
		}
	}

	return out
}

// routable reports whether i has an address beyond its link, which the
// loopback lacks.
func routable(i net.Interface) bool {
	addrs, _ := i.Addrs()

	return slices.ContainsFunc(addrs, func(a net.Addr) bool {
		n, ok := a.(*net.IPNet)

		return ok && n.IP.IsGlobalUnicast()
	})
}
