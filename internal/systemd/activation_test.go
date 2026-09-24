package systemd

import "testing"

func TestListenersWithoutActivation(t *testing.T) {
	t.Setenv("LISTEN_PID", "")

	listeners, err := Listeners()
	if len(listeners) != 0 || err != nil {
		t.Fatalf("expected no listeners outside socket activation, got %v, %v", listeners, err)
	}
}
