package systemd

import (
	"os"
	"strconv"
	"testing"
)

func TestListenersWithoutActivation(t *testing.T) {
	t.Setenv("LISTEN_PID", "")

	listeners, err := Listeners()
	if len(listeners) != 0 || err != nil {
		t.Fatalf("expected no listeners outside socket activation, got %v, %v", listeners, err)
	}
}

func TestListenersRejectInvalidCount(t *testing.T) {
	t.Setenv("LISTEN_PID", strconv.Itoa(os.Getpid()))
	t.Setenv("LISTEN_FDS", "-1")

	if _, err := Listeners(); err == nil {
		t.Fatal("expected error for invalid LISTEN_FDS")
	}
}
