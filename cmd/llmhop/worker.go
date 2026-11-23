package main

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"golang.org/x/sys/unix"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/hubcache"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// internalCmd holds the commands of the NixOS module, which are not public.
type internalCmd struct {
	HubPrune    hubPruneCmd    `cmd:"" help:"Prune the hub cache of a worker to a specification."`
	WaitHealthy waitHealthyCmd `cmd:"" help:"Wait until a server answers on its health path."`
}

type hubPruneCmd struct {
	Spec string `arg:"" type:"path" help:"JSON specification file."`
}

// Run prunes the hub cache of a worker to the JSON specification file.
func (c hubPruneCmd) Run() error {
	var spec hubcache.Specification

	if err := config.DecodeFile(c.Spec, &spec); err != nil {
		return fmt.Errorf("specification: %w", err)
	}

	return hubcache.Prune(spec)
}

type waitHealthyCmd struct {
	PID     int    `arg:"" name:"pid" help:"Process of the server."`
	Address string `arg:"" help:"Backend address of the server."`
	Path    string `arg:"" help:"Health path of the server."`
}

// Run polls GET <path> of the server at a backend address until it answers,
// and fails once the process pid exits before that. As `ExecStartPost=`, it
// holds a unit in `activating` until its server is ready.
func (c waitHealthyCmd) Run() error {
	up, err := upstream.Parse(c.Address, 0)
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodGet, up.URL.JoinPath(c.Path).String(), nil)
	if err != nil {
		return err
	}

	for unix.Kill(c.PID, 0) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := up.Probe(req.WithContext(ctx))
		cancel()

		if err == nil {
			return nil
		}

		time.Sleep(time.Second)
	}

	return fmt.Errorf("the server exited before it answered %s", c.Path)
}
