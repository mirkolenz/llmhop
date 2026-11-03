package main

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/mirkolenz/llmhop/internal/hubcache"
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
