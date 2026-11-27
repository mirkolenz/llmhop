// Package monitor shows the metrics of llmhop and of its engines live in
// the terminal, beside the CPUs, memory, disks, network and GPUs of the
// host, or those alone without a gateway.
package monitor

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	tea "charm.land/bubbletea/v2"
	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/sysstat"
	"github.com/mirkolenz/llmhop/internal/telemetry"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// Run monitors the host and its GPUs every interval until quit, and the
// metrics that llmhop serves on its unix socket unless that is empty.
func Run(socket string, interval time.Duration) error {
	if err := requireTerminal(); err != nil {
		return err
	}

	// The tools that the sampler keeps running stop once the monitor quits.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	l := &live{sampler: sysstat.NewSampler(ctx, interval)}
	source := socket

	if socket == "" {
		host, err := os.Hostname()
		if err != nil {
			return err
		}

		source = host
	} else {
		up, err := upstream.Parse((&url.URL{Scheme: "unix", Path: socket}).String(), 0)
		if err != nil {
			return err
		}

		l.url = up.URL.JoinPath(telemetry.Path).String()
		l.client = &http.Client{Transport: up.Transport}
	}

	return run(source, interval, l.collect)
}

// requireTerminal fails unless the output is a terminal, which a full-screen
// monitor needs, such as that of `ssh -t`, while plain `ssh` allocates
// none.
func requireTerminal() error {
	if _, err := unix.IoctlGetWinsize(int(os.Stdout.Fd()), unix.TIOCGWINSZ); err != nil {
		return errors.New("top needs a terminal, so run `ssh -t <host> llmhop top` remotely")
	}

	return nil
}

// fps bounds how often the terminal is redrawn, which keeps it responsive
// while it idles between polls.
const fps = 10

// baseline bounds the time between the first two polls, the first of which
// only sets the baseline of the rates, so that they show at once.
const baseline = 250 * time.Millisecond

// run shows the snapshots that collect takes every interval of a source
// until quit.
func run(source string, interval time.Duration, collect func(context.Context) *snapshot) error {
	t := &top{source: source, interval: interval, collect: collect, trends: make(trends)}
	_, err := tea.NewProgram(t, tea.WithFPS(fps)).Run()

	return err
}

// top is the state of `llmhop top`, the two latest snapshots, whose
// difference gives the rates, the first of which shows only once the second
// arrives.
type top struct {
	source        string
	interval      time.Duration
	collect       func(context.Context) *snapshot
	last, now     *snapshot
	trends        trends
	width, height int
}

func (t *top) Init() tea.Cmd {
	return t.poll
}

func (t *top) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		t.width, t.height = msg.Width, msg.Height
	case tea.KeyPressMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return t, tea.Quit
		}
	case *snapshot:
		t.last, t.now = t.now, msg
		wait := t.interval

		if t.last == nil {
			wait = min(wait, baseline)
		} else {
			t.trends = t.trends.record(t.frame())
		}

		return t, tea.Tick(wait, func(time.Time) tea.Msg { return t.poll() })
	}

	return t, nil
}

func (t *top) View() tea.View {
	v := tea.NewView(t.render())
	v.AltScreen = true
	v.WindowTitle = "llmhop top"

	return v
}

// poll takes a snapshot.
func (t *top) poll() tea.Msg {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	return t.collect(ctx)
}

func (t *top) frame() frame {
	return frame{t.last, t.now, t.now.at.Sub(t.last.at).Seconds()}
}

// live takes snapshots of the GPUs and the host, and of the metrics of
// llmhop at url unless empty.
type live struct {
	url     string
	client  *http.Client
	sampler *sysstat.Sampler
}

// collect takes a snapshot of the gateway, the GPUs and the host at once.
func (l *live) collect(ctx context.Context) *snapshot {
	s := &snapshot{at: time.Now(), gateway: l.url != ""}

	var wg sync.WaitGroup

	if s.gateway {
		wg.Go(func() { s.samples, s.err = l.scrape(ctx) })
	}

	wg.Go(func() { s.gpus = l.sampler.GPUs(ctx) })
	wg.Go(func() { s.host = l.sampler.Host(ctx) })
	wg.Wait()

	return s
}

func (l *live) scrape(ctx context.Context) ([]telemetry.Sample, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, l.url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := l.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %s", resp.Status)
	}

	return telemetry.Parse(resp.Body)
}
