package main

import (
	"errors"
	"maps"
	"slices"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/monitor"
)

type topCmd struct {
	Interval time.Duration `default:"2s" help:"Time between two polls."`
	Demo     bool          `hidden:"" help:"Show synthetic metrics of two models on two CUDA GPUs and two clients."`
}

// Run monitors the metrics of the first unix socket listener with metrics,
// beside the GPUs and the CPUs and memory of the host, until quit.
func (c topCmd) Run(g *Globals) error {
	if c.Interval <= 0 {
		return errors.New("--interval must be positive")
	}

	if c.Demo {
		return monitor.Demo(c.Interval)
	}

	cfg, err := config.Load(g.Config, false)
	if err != nil {
		return err
	}

	socket, err := metricsSocket(cfg)
	if err != nil {
		return err
	}

	return monitor.Run(socket, c.Interval)
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
