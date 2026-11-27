package sysstat

import (
	"cmp"
	"context"
	"encoding/csv"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// nvidiaQuery is what nvidia-smi reports of each card, in this order.
const nvidiaQuery = "index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,clocks.sm,clocks_event_reasons.active"

// nvidiaLimits names the reasons for a slower clock by their bit.
var nvidiaLimits = []struct {
	bit  uint64
	name string
}{
	{0x4, "power"},
	{0x8, "slowdown"},
	// The software and hardware thermal slowdowns.
	{0x60, "thermal"},
	{0x80, "brake"},
}

// addProcess adds p to procs, merging the processes of one owner, such as
// the workers of a server.
func addProcess(procs []Process, p Process) []Process {
	if i := slices.IndexFunc(procs, func(q Process) bool { return q.Owner == p.Owner }); i >= 0 {
		procs[i].Mem += p.Mem

		return procs
	}

	return append(procs, p)
}

// ownerOf names a process by the innermost systemd service of its cgroup,
// which holds the processes of a container too, else by its PID.
func ownerOf(pid string) string {
	data, err := os.ReadFile(filepath.Join("/proc", pid, "cgroup"))
	if err != nil {
		return "pid " + pid
	}

	// The unified hierarchy is the line `0::<path>`.
	for line := range strings.Lines(string(data)) {
		path, ok := strings.CutPrefix(strings.TrimSpace(line), "0::")
		if !ok {
			continue
		}

		parts := strings.Split(path, "/")

		for _, part := range slices.Backward(parts) {
			if unit, ok := strings.CutSuffix(part, ".service"); ok {
				return unit
			}
		}

		return cmp.Or(parts[len(parts)-1], "pid "+pid)
	}

	return "pid " + pid
}

func mebibytes(s string) float64 {
	return number(s) * (1 << 20)
}

// nvidiaStream keeps nvidia-smi reporting the cards and their processes in
// its loop mode, which queries the driver in place, rather than starting it
// for every read. Each query prints the rows of an iteration with its
// timestamp, the cards in every iteration and the processes only while any
// runs, so the timestamps of the cards tell how recent the processes are.
type nvidiaStream struct {
	interval time.Duration
	mu       sync.Mutex
	// cards holds the latest complete iteration of the cards, and next the
	// one arriving.
	cards, next nvidiaBatch
	// apps holds the latest iteration of the processes.
	apps nvidiaBatch
}

// nvidiaBatch is the rows of one iteration of a query and its timestamp.
type nvidiaBatch struct {
	rows [][]string
	at   time.Time
}

// add adds a row at a time, starting a new iteration unless it is less
// than half the interval of the iterations after the start of the current
// one, and reports whether it did. nvidia-smi stamps every row when it
// queries its card, so the rows of one iteration differ by milliseconds.
func (b *nvidiaBatch) add(at time.Time, row []string, interval time.Duration) bool {
	elapsed := at.Sub(b.at)
	started := elapsed < 0 || elapsed >= interval/2

	if started {
		*b = nvidiaBatch{at: at}
	}

	b.rows = append(b.rows, row)

	return started
}

// nvidiaTime is the layout of the timestamps of nvidia-smi.
const nvidiaTime = "2006/01/02 15:04:05.000"

// startNvidia starts the queries of nvidia-smi every interval until ctx is
// done, or returns nil without nvidia-smi.
func startNvidia(ctx context.Context, interval time.Duration) *nvidiaStream {
	bin, err := exec.LookPath("nvidia-smi")
	if err != nil {
		return nil
	}

	s := &nvidiaStream{interval: interval}

	go s.follow(ctx, bin, "--query-gpu=timestamp,"+nvidiaQuery, s.addCard)
	go s.follow(ctx, bin, "--query-compute-apps=timestamp,gpu_uuid,pid,used_memory", s.addApp)

	return s
}

// addCard adds a row of the cards, completing the previous iteration once
// the next starts.
func (s *nvidiaStream) addCard(at time.Time, row []string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	previous := s.next

	if s.next.add(at, row, s.interval) && previous.rows != nil {
		s.cards = previous
	}
}

// addApp adds a row of the processes.
func (s *nvidiaStream) addApp(at time.Time, row []string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.apps.add(at, row, s.interval)
}

// maxRestartWait bounds the wait before nvidia-smi restarts, which doubles
// from the interval while it reports nothing, as without a working driver.
const maxRestartWait = time.Minute

// follow runs a query in loop mode, passing its rows to add, and restarts
// it once it exits, until ctx is done.
func (s *nvidiaStream) follow(ctx context.Context, bin, query string, add func(time.Time, []string)) {
	loop := "--loop-ms=" + strconv.FormatInt(s.interval.Milliseconds(), 10)
	wait := s.interval

	for {
		if run(ctx, exec.Command(bin, query, "--format=csv,noheader,nounits", loop), add) {
			wait = s.interval
		} else {
			wait = min(2*wait, maxRestartWait)
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// run passes each row of cmd with its timestamp to add and reports whether
// there was any. It stops cmd once its output ends or fails, or ctx is
// done.
func run(ctx context.Context, cmd *exec.Cmd, add func(time.Time, []string)) bool {
	out, err := cmd.StdoutPipe()
	if err != nil {
		return false
	}

	if err := cmd.Start(); err != nil {
		return false
	}

	stop := context.AfterFunc(ctx, func() { _ = cmd.Process.Kill() })
	defer func() {
		stop()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	r := csv.NewReader(out)
	r.TrimLeadingSpace = true
	r.FieldsPerRecord = -1

	added := false

	for {
		row, err := r.Read()
		if err != nil {
			return added
		}

		if at, err := time.ParseInLocation(nvidiaTime, row[0], time.Local); err == nil {
			add(at, row[1:])
			added = true
		}
	}
}

// read returns the cards of the latest iteration with the processes of an
// iteration of their query since the iteration of the cards before, or none
// if the cards stopped reporting, such as on a driver failure.
func (s *nvidiaStream) read() []GPU {
	if s == nil {
		return nil
	}

	s.mu.Lock()
	cards, apps := s.cards, s.apps
	s.mu.Unlock()

	if time.Since(cards.at) > 2*s.interval+s.interval/2 {
		return nil
	}

	procs := make(map[string][]Process)

	if cards.at.Sub(apps.at) < s.interval {
		for _, r := range apps.rows {
			if len(r) == 3 {
				procs[r[0]] = addProcess(procs[r[0]], Process{ownerOf(r[1]), mebibytes(r[2])})
			}
		}
	}

	var out []GPU

	for _, r := range cards.rows {
		if len(r) == 11 {
			out = append(out, nvidiaCard(r, procs[r[1]]))
		}
	}

	return out
}

// nvidiaCard is the card of a row of nvidiaQuery, used by procs.
func nvidiaCard(r []string, procs []Process) GPU {
	g := newGPU(r[0], r[2])
	g.Busy = number(r[3]) / 100
	g.MemUsed = mebibytes(r[4])
	g.MemTotal = mebibytes(r[5])
	g.Temp = number(r[6])
	g.Power = number(r[7])
	g.PowerCap = number(r[8])
	g.Clock = number(r[9])
	g.Processes = procs

	if bits, err := strconv.ParseUint(strings.TrimPrefix(r[10], "0x"), 16, 64); err == nil {
		for _, l := range nvidiaLimits {
			if bits&l.bit != 0 {
				g.Limits = append(g.Limits, l.name)
			}
		}
	}

	return g
}
