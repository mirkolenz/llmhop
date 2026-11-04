package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"syscall"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
	"github.com/mirkolenz/llmhop/internal/hubcache"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// hubPrune prunes the hub cache of a worker to the JSON specification file.
func hubPrune(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: llmhop internal hub-prune <spec-file>")
	}

	var spec hubcache.Specification

	if err := config.DecodeFile(args[0], &spec); err != nil {
		return fmt.Errorf("specification: %w", err)
	}

	return hubcache.Prune(spec)
}

// waitHealthy polls GET <path> of the server at a backend address until it
// answers, and fails once the process pid exits before that. As
// `ExecStartPost=`, it holds a unit in `activating` until its server is ready.
func waitHealthy(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: llmhop internal wait-healthy <pid> <address> <path>")
	}

	pid, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("pid: %w", err)
	}

	up, err := upstream.Parse(args[1])
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodGet, up.URL.JoinPath(args[2]).String(), nil)
	if err != nil {
		return err
	}

	for syscall.Kill(pid, 0) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := up.Probe(req.WithContext(ctx))
		cancel()

		if err == nil {
			return nil
		}

		time.Sleep(time.Second)
	}

	return fmt.Errorf("the server exited before it answered %s", args[2])
}
