package monitor

import (
	"maps"
	"math"
	"slices"
	"strconv"
	"time"

	"github.com/mirkolenz/llmhop/internal/sysstat"
	"github.com/mirkolenz/llmhop/internal/telemetry"
)

// snapshot is what one poll observed.
type snapshot struct {
	at time.Time
	// gateway is whether the snapshot is of a gateway, even of one that
	// failed to report.
	gateway bool
	samples []telemetry.Sample
	// err is why the gateway failed to report its samples.
	err  error
	gpus []sysstat.GPU
	// host is nil where nothing reports it.
	host *sysstat.Host
	// byName and byKey index the samples by their name and by their series
	// once needed.
	byName map[string][]telemetry.Sample
	byKey  map[string]float64
}

// index indexes the samples once.
func (s *snapshot) index() {
	if s.byName != nil {
		return
	}

	s.byName = make(map[string][]telemetry.Sample)
	s.byKey = make(map[string]float64, len(s.samples))

	for _, x := range s.samples {
		s.byName[x.Name] = append(s.byName[x.Name], x)
		s.byKey[seriesKey(x)] = x.Value
	}
}

// series returns the samples named name.
func (s *snapshot) series(name string) []telemetry.Sample {
	s.index()

	return s.byName[name]
}

// seriesKey identifies the series of a sample by its name and labels.
func seriesKey(x telemetry.Sample) string {
	var kv []string

	for _, k := range slices.Sorted(maps.Keys(x.Labels)) {
		kv = append(kv, k, x.Labels[k])
	}

	return x.Name + telemetry.Labels(kv...)
}

// matcher selects series by their labels.
type matcher func(labels map[string]string) bool

// labeled matches the series with the label pairs kv.
func labeled(kv ...string) matcher {
	want := telemetry.Pairs(kv...)

	return func(labels map[string]string) bool {
		for k, v := range want {
			if labels[k] != v {
				return false
			}
		}

		return true
	}
}

// all matches every series.
var all = labeled()

// status matches the series of a status from lo to hi, except for skip.
func status(lo, hi int, skip ...int) matcher {
	return func(labels map[string]string) bool {
		code, err := strconv.Atoi(labels[telemetry.Status])

		return err == nil && lo <= code && code <= hi && !slices.Contains(skip, code)
	}
}

// both matches the series that a and b match.
func both(a, b matcher) matcher {
	return func(labels map[string]string) bool { return a(labels) && b(labels) }
}

// values returns the values of the series name that m matches.
func (s *snapshot) values(name string, m matcher) []float64 {
	var out []float64

	for _, x := range s.series(name) {
		if m(x.Labels) {
			out = append(out, x.Value)
		}
	}

	return out
}

// value combines the series name that m matches, or returns NaN without
// any.
func (s *snapshot) value(name string, m matcher) float64 {
	values := s.values(name, m)
	if len(values) == 0 {
		return math.NaN()
	}

	total := values[0]

	for _, v := range values[1:] {
		total = telemetry.Combine(name, total, v)
	}

	return total
}

// labels returns the sorted distinct values of a label over the series
// name.
func (s *snapshot) labels(label, name string) []string {
	var out []string

	for _, x := range s.series(name) {
		out = append(out, x.Labels[label])
	}

	slices.Sort(out)

	return slices.Compact(out)
}

// frame is the latest snapshot and the one before.
type frame struct {
	last, now *snapshot
	seconds   float64
}

// value returns the present value of a series, or the increase per second
// of a counter, or NaN.
func (f frame) value(name string, m matcher) float64 {
	if telemetry.Counter(name) {
		return f.rate(name, m)
	}

	return f.now.value(name, m)
}

// count returns the present value of a series, zero without any, such as
// the requests of a model that runs none.
func (f frame) count(name string, m matcher) float64 {
	if v := f.now.value(name, m); !math.IsNaN(v) {
		return v
	}

	return 0
}

// delta returns the increase of a counter between the snapshots, summed
// over the series that m matches, of which a counter that fell restarted
// from zero. A series absent before counts from zero if its source reported
// then, since llmhop creates a counter with its first observation, but
// counts nothing if its engine missed that scrape, leaving its baseline
// unknown. It returns NaN without any such series.
func (f frame) delta(name string, m matcher) float64 {
	f.last.index()

	total, found := 0.0, false

	for _, x := range f.now.series(name) {
		if !m(x.Labels) {
			continue
		}

		before, ok := f.last.byKey[seriesKey(x)]

		if !ok && !f.last.reported(x) {
			continue
		}

		found = true

		if x.Value >= before {
			total += x.Value - before
		} else {
			total += x.Value
		}
	}

	if !found {
		return math.NaN()
	}

	return total
}

// reported reports whether the source of the series of x reported in s,
// the engines of its server or else the gateway.
func (s *snapshot) reported(x telemetry.Sample) bool {
	if !telemetry.FromEngine(x.Name) {
		return s.err == nil
	}

	return s.value(telemetry.EngineUp, labeled(telemetry.Model, x.Labels[telemetry.Model], telemetry.Server, x.Labels[telemetry.Server])) == 1
}

// rate returns the increase of a counter per second, or NaN.
func (f frame) rate(name string, m matcher) float64 {
	if f.seconds <= 0 {
		return math.NaN()
	}

	return f.delta(name, m) / f.seconds
}

// ratio returns the increase of one counter per that of another, or NaN
// without any increase.
func (f frame) ratio(num, den string, m matcher) float64 {
	d := f.delta(den, m)
	if !(d > 0) {
		return math.NaN()
	}

	return f.delta(num, m) / d
}

// mean returns the mean of the observations of a histogram between the
// snapshots, or NaN.
func (f frame) mean(histogram string, m matcher) float64 {
	return f.ratio(histogram+"_sum", histogram+"_count", m)
}

// models returns the names of the models.
func (f frame) models() []string {
	return f.now.labels(telemetry.Model, telemetry.QueuedRequests)
}

// clients returns the names of the configured clients, or the anonymous
// one without auth, whose slot seconds the gateway reports from the start,
// unlike the requests, which also count those that no client sent.
func (f frame) clients() []string {
	return f.now.labels(telemetry.Client, telemetry.SlotSeconds)
}

// hostRow is a resource of the host with its used share and what details
// it.
type hostRow struct {
	name, detail string
	share        float64
}

// hostRows returns the CPUs, the load, the memory and the swap of the
// host, none without it.
func (f frame) hostRows() []hostRow {
	h := f.now.host

	if h == nil {
		return nil
	}

	cpu := math.NaN()

	if f.last.host != nil {
		cpu = h.CPU(*f.last.host)
	}

	return []hostRow{
		{"cpu", fmtAmount(cpu*float64(h.CPUs), float64(h.CPUs), 1, "CPUs"), cpu},
		{"load", fmtAmount(h.Load[0], float64(h.CPUs), 1, "CPUs"), h.LoadShare()},
		{"memory", fmtUsage(h.MemTotal-h.MemAvailable, h.MemTotal), h.MemoryShare()},
		{"swap", fmtUsage(h.SwapTotal-h.SwapFree, h.SwapTotal), h.SwapShare()},
	}
}

// since returns the increase per second of a counter of the host since its
// value before, of which a counter that fell restarted from zero, or NaN
// without one.
func (f frame) since(now, before float64, ok bool) float64 {
	if !ok || f.seconds <= 0 {
		return math.NaN()
	}

	if now < before {
		before = 0
	}

	return (now - before) / f.seconds
}

// lastHost returns the host of the previous snapshot, or one without
// anything.
func (f frame) lastHost() *sysstat.Host {
	if f.last.host == nil {
		return &sysstat.Host{}
	}

	return f.last.host
}

// byKey indexes items by key.
func byKey[T any](items []T, key func(T) string) map[string]T {
	out := make(map[string]T, len(items))

	for _, x := range items {
		out[key(x)] = x
	}

	return out
}

// diskRow is a filesystem with the bytes its device read and wrote per
// second and its busy share.
type diskRow struct {
	sysstat.Disk
	read, written, busy float64
}

// disks returns the filesystems of the host.
func (f frame) disks() []diskRow {
	if f.now.host == nil {
		return nil
	}

	before := byKey(f.lastHost().Disks, func(d sysstat.Disk) string { return d.Mount })

	var rows []diskRow

	for _, d := range f.now.host.Disks {
		b, ok := before[d.Mount]
		// Overlapping reads and writes may count more than the time passed.
		busy := min(f.since(d.Busy, b.Busy, ok), 1)
		rows = append(rows, diskRow{d, f.since(d.Read, b.Read, ok), f.since(d.Written, b.Written, ok), busy})
	}

	return rows
}

// interfaceRow is a network interface with the bytes it received and sent
// per second.
type interfaceRow struct {
	name           string
	received, sent float64
}

// interfaces returns the network interfaces of the host.
func (f frame) interfaces() []interfaceRow {
	if f.now.host == nil {
		return nil
	}

	before := byKey(f.lastHost().Interfaces, func(i sysstat.Interface) string { return i.Name })

	var rows []interfaceRow

	for _, i := range f.now.host.Interfaces {
		b, ok := before[i.Name]
		rows = append(rows, interfaceRow{i.Name, f.since(i.Received, b.Received, ok), f.since(i.Sent, b.Sent, ok)})
	}

	return rows
}
