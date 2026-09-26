package main

import (
	"errors"
	"os/exec"
	"testing"
)

func TestSuperviseKillsChildWhenReadinessFails(t *testing.T) {
	cmd := exec.Command("sleep", "60")
	readyErr := errors.New("notification failed")

	code, err := supervise(cmd, func() error { return readyErr })
	if code != 1 || !errors.Is(err, readyErr) {
		t.Fatalf("got code %d and error %v, want 1 and readiness error", code, err)
	}

	if cmd.ProcessState == nil {
		t.Fatal("child was not reaped")
	}
}
