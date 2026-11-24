package main

import (
	"bufio"
	"cmp"
	"context"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/router"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

type topCmd struct {
	Interval time.Duration `default:"2s" help:"Time between two polls."`
}

// Run polls the metrics of the first unix socket listener with metrics
// until interrupted, showing the rates between two polls.
func (c topCmd) Run(g *Globals) error {
	if c.Interval <= 0 {
		return errors.New("--interval must be positive")
	}

	cfg, err := config.Load(g.Config, false)
	if err != nil {
		return err
	}

	socket, err := metricsSocket(cfg)
	if err != nil {
		return err
	}

	up, err := upstream.Parse((&url.URL{Scheme: "unix", Path: socket}).String(), 0)
	if err != nil {
		return err
	}

	client := &http.Client{Transport: up.Transport, Timeout: 10 * time.Second}
	metrics := up.URL.JoinPath("llmhop/metrics").String()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, unix.SIGTERM)
	defer stop()

	last, err := poll(ctx, client, metrics)
	if err != nil {
		return fmt.Errorf("poll %s: %w", socket, err)
	}

	// The alternate screen keeps the terminal as it was once quit.
	fmt.Print("\x1b[?1049h")
	defer fmt.Print("\x1b[?1049l")

	ticker := time.NewTicker(c.Interval)
	defer ticker.Stop()

	// The first frame compares the first sample with itself, without rates.
	now := last

	for {
		// A frame is written at once, so that it never flickers.
		frame := fmt.Sprintf("\x1b[H\x1b[2Jllmhop on %s, Ctrl+C quits\n\nModels\n%s\nClients\n%s", socket, table(modelRows(last, now)), table(clientRows(last, now)))

		if _, err := os.Stdout.WriteString(frame); err != nil {
			return err
		}

		last = now

		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}

		now, err = poll(ctx, client, metrics)
		if ctx.Err() != nil {
			return nil
		} else if err != nil {
			return fmt.Errorf("poll %s: %w", socket, err)
		}
	}
}

// metricsSocket returns the socket of the first unix socket listener with
// metrics by name.
func metricsSocket(cfg *config.Config) (string, error) {
	for _, name := range slices.Sorted(maps.Keys(cfg.Listen)) {
		if l := cfg.Listen[name]; l.Metrics && l.Socket != "" {
			return l.Socket, nil
		}
	}

	return "", errors.New("the gateway has no unix socket listener with metrics")
}

// sample is the metrics of llmhop at a time.
type sample struct {
	at time.Time
	router.Metrics
}

func poll(ctx context.Context, client *http.Client, url string) (sample, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return sample{}, err
	}

	resp, err := client.Do(req)
	if err != nil {
		return sample{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return sample{}, fmt.Errorf("status %s", resp.Status)
	}

	s := sample{at: time.Now()}

	return s, json.UnmarshalRead(resp.Body, &s.Metrics)
}

// counts is the number of requests of a group and of the failed ones.
type counts struct{ all, failed int }

// delta is the requests of each group of two samples.
type delta struct {
	last, now map[string]counts
	seconds   float64
}

// newDelta tallies the requests of last and now by the group that key
// returns.
func newDelta(last, now sample, key func(router.Requests) string) delta {
	tally := func(s sample) map[string]counts {
		groups := make(map[string]counts)

		for _, r := range s.Requests {
			c := groups[key(r)]
			c.all += r.Count

			if r.Status >= 400 {
				c.failed += r.Count
			}

			groups[key(r)] = c
		}

		return groups
	}

	return delta{tally(last), tally(now), now.at.Sub(last.at).Seconds()}
}

// activity returns the cells of the requests of a group in flight, and of
// all and failed ones per second, zero across a restart and unknown
// without time between the samples.
func (d delta) activity(group string, flight int) []string {
	rate := func(before, after int) string {
		if d.seconds <= 0 {
			return "-"
		}

		return strconv.FormatFloat(float64(max(0, after-before))/d.seconds, 'f', 1, 64)
	}

	last, now := d.last[group], d.now[group]

	return []string{strconv.Itoa(flight), rate(last.all, now.all), rate(last.failed, now.failed)}
}

func modelRows(last, now sample) [][]string {
	d := newDelta(last, now, func(r router.Requests) string { return r.Model })
	models := make(map[string]router.ModelMetrics)

	for name := range d.now {
		if name != "" {
			models[name] = router.ModelMetrics{Name: name}
		}
	}

	for _, m := range now.Models {
		models[m.Name] = m
	}

	rows := [][]string{{"MODEL", "READY", "QUEUE", "FLIGHT", "REQ/S", "ERR/S"}}

	for _, name := range slices.Sorted(maps.Keys(models)) {
		m := models[name]
		ready := "-"

		if m.Up != nil {
			up := 0

			for _, ok := range m.Up {
				if ok {
					up++
				}
			}

			ready = fmt.Sprintf("%d/%d", up, len(m.Up))
		}

		flight := 0

		for _, n := range m.Running {
			flight += n
		}

		rows = append(rows, append([]string{name, ready, strconv.Itoa(m.Queued)}, d.activity(name, flight)...))
	}

	return rows
}

func clientRows(last, now sample) [][]string {
	d := newDelta(last, now, func(r router.Requests) string { return r.Client })
	flight := make(map[string]int)

	// A client whose first requests still run has only those in flight.
	for _, m := range now.Models {
		for client, n := range m.Running {
			flight[client] += n
		}
	}

	for client := range d.now {
		if _, ok := flight[client]; !ok {
			flight[client] = 0
		}
	}

	rows := [][]string{{"CLIENT", "FLIGHT", "REQ/S", "ERR/S"}}

	for _, client := range slices.Sorted(maps.Keys(flight)) {
		rows = append(rows, append([]string{cmp.Or(client, "-")}, d.activity(client, flight[client])...))
	}

	return rows
}

type usageCmd struct {
	By string `enum:"client,model,policy" default:"client" help:"Group by client, model or policy."`
}

// logEntry is a line of llmhop's log, a request with msg "request".
type logEntry struct {
	Msg    string `json:"msg"`
	Client string `json:"client"`
	Model  string `json:"model"`
	Policy string `json:"policy"`
	Status int    `json:"status"`
}

// Run sums the request lines of the log on stdin by group, skipping every
// other line, so that any log tool can select the source and period.
func (c usageCmd) Run() error {
	type usage struct{ requests, errors int }

	groups := make(map[string]usage)
	log := bufio.NewReader(os.Stdin)

	for {
		line, err := log.ReadBytes('\n')
		if errors.Is(err, io.EOF) && len(line) == 0 {
			break
		} else if err != nil && !errors.Is(err, io.EOF) {
			return fmt.Errorf("read log: %w", err)
		}

		var e logEntry

		if json.Unmarshal(line, &e) != nil || e.Msg != "request" {
			continue
		}

		group := e.Client

		switch c.By {
		case "model":
			group = e.Model
		case "policy":
			group = e.Policy
		}

		group = cmp.Or(group, "-")
		u := groups[group]
		u.requests++

		if e.Status >= 400 {
			u.errors++
		}

		groups[group] = u
	}

	rows := [][]string{{strings.ToUpper(c.By), "REQUESTS", "ERRORS"}}

	for _, group := range slices.Sorted(maps.Keys(groups)) {
		u := groups[group]
		rows = append(rows, []string{group, strconv.Itoa(u.requests), strconv.Itoa(u.errors)})
	}

	fmt.Print(table(rows))

	return nil
}
