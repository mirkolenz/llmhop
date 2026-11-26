package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mirkolenz/llmhop/internal/config"
)

func TestConcurrentRequestLimit(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)
	fast, _ := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"a": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1},
		"b": {URLs: []string{fast.URL}, MaxConcurrentRequests: 1},
	}})

	done := make(chan struct{})

	go func() {
		send(t, h, http.MethodPost, "/", `{"model":"a"}`, "")
		close(done)
	}()

	// Returns once the first request holds the only slot of model a.
	<-entered

	if rec := send(t, h, http.MethodPost, "/", `{"model":"a"}`, ""); rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "1" {
		t.Errorf("saturated model got status %d, want 429", rec.Code)
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"b"}`, ""); rec.Code != http.StatusOK {
		t.Errorf("other model got status %d, want 200", rec.Code)
	}

	close(release)
	<-done
}

// A stream is aborted once it sends nothing for its idle timeout, which
// every event restarts.
func TestStreamIdleTimeout(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")

		for range 3 {
			_, _ = io.WriteString(w, "data: {}\n\n")
			_ = http.NewResponseController(w).Flush()
			time.Sleep(600 * time.Millisecond)
		}

		<-r.Context().Done()
	}))
	t.Cleanup(backend.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{backend.URL}, StreamIdleTimeoutSeconds: 1}}})

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Body.String() != strings.Repeat("data: {}\n\n", 3) {
		t.Fatalf("got %q", rec.Body)
	}
}

func TestQueueAndResponseTimeout(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{
		"m": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1, QueueTimeoutSeconds: 10, ResponseTimeoutSeconds: 1},
	}})

	first := make(chan int)

	go func() { first <- send(t, h, http.MethodPost, "/", `{"model":"m"}`, "").Code }()

	<-entered

	// The second request waits for the slot of the first, which times out.
	second := make(chan int)

	go func() { second <- send(t, h, http.MethodPost, "/", `{"model":"m"}`, "").Code }()

	if code := <-first; code != http.StatusGatewayTimeout {
		t.Errorf("first request got status %d, want 504", code)
	}

	<-entered
	release <- struct{}{}
	close(release)

	if code := <-second; code != http.StatusOK && code != http.StatusGatewayTimeout {
		t.Errorf("queued request got status %d", code)
	}
}

// A reload shares the limits, so requests of the previous router count.
func TestLimitsSharedAcrossRouters(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		entered <- struct{}{}
		<-release
	}))
	t.Cleanup(slow.Close)

	limits := &Limits{}
	cfg := &config.Config{Models: map[string]config.Model{"m": {URLs: []string{slow.URL}, MaxConcurrentRequests: 1}}}

	old, err := New(cfg, limits)
	if err != nil {
		t.Fatal(err)
	}

	reloaded, err := New(cfg, limits)
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})

	go func() {
		send(t, old, http.MethodPost, "/", `{"model":"m"}`, "")
		close(done)
	}()

	<-entered

	if rec := send(t, reloaded, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusTooManyRequests {
		t.Errorf("reloaded router got status %d, want 429", rec.Code)
	}

	close(release)
	<-done
}
