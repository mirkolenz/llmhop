package main

import (
	"errors"
	"io/fs"
	"maps"
	"slices"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/monitor"
)

type topCmd struct {
	Interval time.Duration `default:"2s" help:"Time between two polls."`
	Demo     bool          `hidden:"" help:"Show synthetic metrics of two models on two CUDA GPUs, two clients, two disks and two interfaces."`
}

// Run monitors the host with its GPUs, disks and network until quit, and
// the gateway if its config names a unix socket listener with metrics.
func (c topCmd) Run(g *Globals) error {
	if c.Interval <= 0 {
		return errors.New("--interval must be positive")
	}

	if c.Demo {
		return monitor.Demo(c.Interval)
	}

	socket, err := metricsSocket(g.Config)
	if err != nil {
		return err
	}

	return monitor.Run(socket, c.Interval)
}

// metricsSocket returns the socket of the first unix socket listener with
// metrics by name, or none without a config or such a listener, which
// leaves the host alone to monitor.
func metricsSocket(path string) (string, error) {
	cfg, err := config.Load(path, false)

	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", nil
	case err != nil:
		return "", err
	}

	for _, name := range slices.Sorted(maps.Keys(cfg.Listen)) {
		if l := cfg.Listen[name]; l.Metrics && l.Socket != "" {
			return l.Socket, nil
		}
	}

	return "", nil
}
