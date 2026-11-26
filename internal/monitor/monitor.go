// Package monitor shows the metrics of llmhop and of its engines live in
// the terminal, beside the GPUs and the CPUs and memory of the host.
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

// Run monitors the metrics that llmhop serves on its unix socket, polling
// every interval until quit.
func Run(socket string, interval time.Duration) error {
	if err := requireTerminal(); err != nil {
		return err
	}

	up, err := upstream.Parse((&url.URL{Scheme: "unix", Path: socket}).String(), 0)
	if err != nil {
		return err
	}

	// The tools that the sampler keeps running stop once the monitor quits.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	g := &gateway{
		url:     up.URL.JoinPath(telemetry.Path).String(),
		client:  &http.Client{Transport: up.Transport},
		sampler: sysstat.NewSampler(ctx, interval),
	}

	return run(socket, interval, g.collect)
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

// run shows the snapshots that collect takes every interval of a source
// until quit.
func run(source string, interval time.Duration, collect func(context.Context) *snapshot) error {
	t := &top{source: source, interval: interval, collect: collect, trends: make(trends)}
	_, err := tea.NewProgram(t, tea.WithFPS(fps)).Run()

	return err
}

// top is the state of `llmhop top`, the two latest snapshots, whose
// difference gives the rates.
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

		if t.last == nil {
			t.last = msg
		}

		t.trends = t.trends.record(t.frame())

		return t, tea.Tick(t.interval, func(time.Time) tea.Msg { return t.poll() })
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

// gateway takes snapshots of the metrics of llmhop, the GPUs and the host.
type gateway struct {
	url     string
	client  *http.Client
	sampler *sysstat.Sampler
}

// collect takes a snapshot of the gateway, the GPUs and the host at once.
func (g *gateway) collect(ctx context.Context) *snapshot {
	s := &snapshot{at: time.Now()}

	var wg sync.WaitGroup

	wg.Go(func() { s.samples, s.err = g.scrape(ctx) })
	wg.Go(func() { s.gpus = g.sampler.GPUs(ctx) })
	wg.Go(func() { s.host = g.sampler.Host() })
	wg.Wait()

	return s
}

func (g *gateway) scrape(ctx context.Context) ([]telemetry.Sample, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := g.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %s", resp.Status)
	}

	return telemetry.Parse(resp.Body)
}
