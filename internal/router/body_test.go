package router

import (
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"testing/iotest"

	"github.com/mirkolenz/llmhop/internal/config"
)

func TestBodyLimit(t *testing.T) {
	cases := []struct {
		name          string
		maxBytes      int64
		contentLength int64
		body          io.Reader
		wantCode      int
	}{
		{"known length is rejected before reading", 4, 5, iotest.ErrReader(errors.New("body was read")), http.StatusRequestEntityTooLarge},
		{"unknown length is capped while reading", 4, -1, strings.NewReader(`{"model":"m"}`), http.StatusRequestEntityTooLarge},
		{"zero disables the body limit", 0, 13, strings.NewReader(`{"model":"m"}`), http.StatusNotFound},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newRouter(t, &config.Config{MaxBodyBytes: c.maxBytes, Models: map[string]config.Model{"other": {URLs: []string{"http://127.0.0.1:1"}}}})
			req := httptest.NewRequest(http.MethodPost, "/", c.body)
			req.ContentLength = c.contentLength
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != c.wantCode {
				t.Fatalf("got status %d, want %d", rec.Code, c.wantCode)
			}
		})
	}
}

func TestBufferedBytesLimit(t *testing.T) {
	srv, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedBytes: 16,
		Models:           map[string]config.Model{"m": {URLs: []string{srv.URL}}},
	})

	// The first body arrives slowly, so its partial body holds 10 bytes.
	body, writer := io.Pipe()
	done := make(chan struct{})

	go func() {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", body))
		close(done)
	}()

	// The second write returns only once the router reads again, so the first is charged.
	for _, chunk := range []string{`{"model":`, " "} {
		if _, err := writer.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}

	if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("buffered request got status %d, want 503", rec.Code)
	}

	// Path-routed bodies stream, so they need no budget.
	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/m/", "{}", ""); rec.Code != http.StatusOK {
		t.Errorf("streamed request got status %d, want 200", rec.Code)
	}

	_ = writer.CloseWithError(io.ErrUnexpectedEOF)
	<-done

	// The failed read released its bytes.
	for range 2 {
		if rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, ""); rec.Code != http.StatusOK {
			t.Errorf("buffered request got status %d, want 200", rec.Code)
		}
	}
}

func TestBufferedBytesReleasedOnceResponding(t *testing.T) {
	unblock := make(chan struct{})
	streaming := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
		_ = http.NewResponseController(w).Flush()
		<-unblock
	}))
	t.Cleanup(streaming.Close)
	fast, _ := startBackend(t)
	h := newRouter(t, &config.Config{
		MaxBufferedBytes: 16,
		Models:           map[string]config.Model{"slow": {URLs: []string{streaming.URL}}, "fast": {URLs: []string{fast.URL}}},
	})

	// The router releases the bytes once it accepts the response, before it
	// writes the header.
	rec, done := &headerSignal{httptest.NewRecorder(), make(chan struct{})}, make(chan struct{})

	go func() {
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"slow"}`)))
		close(done)
	}()

	<-rec.wrote

	// The slow response still streams, but its body can no longer be resent.
	if rec := send(t, h, http.MethodPost, "/", `{"model":"fast"}`, ""); rec.Code != http.StatusOK {
		t.Errorf("buffered request got status %d, want 200", rec.Code)
	}

	close(unblock)
	<-done
}

// headerSignal closes wrote once the header is written.
type headerSignal struct {
	*httptest.ResponseRecorder
	wrote chan struct{}
}

func (h *headerSignal) WriteHeader(code int) {
	h.ResponseRecorder.WriteHeader(code)
	close(h.wrote)
}

func TestBufferedIdempotentRetry(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)

		// The second request reuses the connection, which closes before any response.
		if calls.Add(1) == 2 {
			conn, _, _ := http.NewResponseController(w).Hijack()
			_ = conn.Close()
		}
	}))
	t.Cleanup(srv.Close)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"m": {URLs: []string{srv.URL}}}})

	for range 2 {
		req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"m"}`))
		req.Header.Set("Idempotency-Key", "k")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Errorf("idempotent request got status %d, want 200", rec.Code)
		}
	}

	if n := calls.Load(); n != 3 {
		t.Errorf("backend got %d requests, want 3", n)
	}
}

func TestMultipartModel(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{Models: map[string]config.Model{"whisper": {URLs: []string{backend.URL}}}})

	var body strings.Builder
	form := multipart.NewWriter(&body)
	_ = form.WriteField("model", "whisper")
	_ = form.Close()

	req := httptest.NewRequest(http.MethodPost, "/v1/audio/transcriptions", strings.NewReader(body.String()))
	req.Header.Set("Content-Type", form.FormDataContentType())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || captured.body != body.String() {
		t.Fatalf("got status %d, backend saw %q", rec.Code, captured.body)
	}

	// The backend would read another model than the one routed by.
	body.Reset()
	form = multipart.NewWriter(&body)
	_ = form.WriteField("model", "whisper")
	_ = form.WriteField("model", "other")
	_ = form.Close()

	req = httptest.NewRequest(http.MethodPost, "/v1/audio/transcriptions", strings.NewReader(body.String()))
	req.Header.Set("Content-Type", form.FormDataContentType())
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("duplicate model got status %d", rec.Code)
	}
}
