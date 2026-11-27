package sysstat

import (
	"context"
	"testing"
	"time"
)

// The cards of an iteration hold together although nvidia-smi stamps each
// a little later, and complete once all have arrived. The processes of a
// card hold while their query reports them as recently as the cards, and
// vanish once only the cards go on, since their query prints nothing while
// none runs.
func TestNvidiaStream(t *testing.T) {
	s := newNvidiaStream(2 * time.Second)
	now := time.Now()
	cards := [][]string{
		{"2", "0", "GPU-a", "NVIDIA H100", "50", "1024", "81920", "60", "300", "700", "1980", "0x60"},
		{"2", "1", "GPU-b", "NVIDIA H100", "0", "0", "81920", "40", "80", "700", "345", "0x0"},
	}
	addCards := func(at time.Time) {
		for i, card := range cards {
			s.addCard(at.Add(time.Duration(i)*5*time.Millisecond), card)
		}
	}
	processes := func() int {
		gpus := s.read(context.Background())
		if len(gpus) != len(cards) {
			t.Fatalf("got %d cards, want %d", len(gpus), len(cards))
		}

		return len(gpus[0].Processes)
	}

	s.addApp(now, []string{"GPU-a", "1", "512"})
	addCards(now)

	if n := processes(); n != 1 {
		t.Errorf("got %d processes, want 1", n)
	}

	addCards(now.Add(2 * time.Second))

	if n := processes(); n != 0 {
		t.Errorf("got %d processes after they exited, want 0", n)
	}

	if limits := s.read(context.Background())[0].Limits; len(limits) != 1 || limits[0] != "thermal" {
		t.Errorf("got limits %v", limits)
	}
}
