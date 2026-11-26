package sysstat

import (
	"testing"
	"time"
)

// The processes of a card hold while their query reports them as recently
// as the cards, and vanish once only the cards go on, since their query
// prints nothing while none runs.
func TestNvidiaStream(t *testing.T) {
	s := &nvidiaStream{interval: 2 * time.Second}
	now := time.Now()
	card := []string{"0", "GPU-a", "NVIDIA H100", "50", "1024", "81920", "60", "300", "700", "1980", "0x60"}
	processes := func() int {
		gpus := s.read()
		if len(gpus) != 1 {
			t.Fatalf("got %d cards", len(gpus))
		}

		return len(gpus[0].Processes)
	}

	s.addApp(now.Add(-2*time.Second), []string{"GPU-a", "1", "512"})
	s.addCard(now.Add(-2*time.Second), card)
	s.addCard(now, card)

	if n := processes(); n != 1 {
		t.Errorf("got %d processes, want 1", n)
	}

	s.addCard(now.Add(2*time.Second), card)

	if n := processes(); n != 0 {
		t.Errorf("got %d processes after they exited, want 0", n)
	}

	if limits := s.read()[0].Limits; len(limits) != 1 || limits[0] != "thermal" {
		t.Errorf("got limits %v", limits)
	}
}
