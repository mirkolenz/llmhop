package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"syscall"
	"time"

	"github.com/mirkolenz/llmhop/internal/hubcache"
	"github.com/mirkolenz/llmhop/internal/upstream"
)

// hubPrune prunes the hub cache of a worker to its JSON specification.
func hubPrune(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: llmhop hub-prune <specification>")
	}

	var spec hubcache.Specification

	if err := json.Unmarshal([]byte(args[0]), &spec); err != nil {
		return fmt.Errorf("specification: %w", err)
	}

	return hubcache.Prune(spec)
}

// waitHealthy polls GET /health of the server at a backend address until it
// answers, and fails once the process `$MAINPID` exits before that. As
// `ExecStartPost=`, it holds a unit in `activating` until its server is ready.
func waitHealthy(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: llmhop wait-healthy <url>")
	}

	pid, err := strconv.Atoi(os.Getenv("MAINPID"))
	if err != nil {
		return fmt.Errorf("MAINPID: %w", err)
	}

	up, err := upstream.Parse(args[0])
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodGet, up.URL.JoinPath("health").String(), nil)
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

	return errors.New("the server exited before it answered /health")
}
