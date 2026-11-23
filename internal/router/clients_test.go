package router

import (
	"encoding/json/v2"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/mirkolenz/llmhop/internal/apikey"
	"github.com/mirkolenz/llmhop/internal/config"
)

func TestPolicies(t *testing.T) {
	backend, captured := startBackend(t)
	h := newRouter(t, &config.Config{
		Defaults: config.Policy{Models: []string{"m"}},
		Policies: map[string]config.Policy{"p": {
			RequestsPerMinute: new(uint32(2)),
			Models:            []string{"m*", "detector"},
		}},
		Clients: map[string]config.Client{
			"alice": {KeyHash: apikey.Of("llmhop_a-secret"), PolicyName: "p"},
			"bob":   {KeyHash: apikey.Of("llmhop_b-secret")},
			"dave":  {KeyHash: apikey.Of("llmhop_d-secret"), ExpiresAt: time.Now().Add(-time.Hour)},
		},
		Models: map[string]config.Model{
			"m":        {URLs: []string{backend.URL}},
			"other":    {URLs: []string{backend.URL}},
			"detector": {URLs: []string{backend.URL}, Unlisted: true},
		},
	})

	cases := []struct {
		name, key, path, body string
		status                int
		code                  string
	}{
		{"forbidden model", "Bearer llmhop_b-secret", "/", `{"model":"other"}`, http.StatusForbidden, "model_not_allowed"},
		{"forbidden model to retrieve", "Bearer llmhop_b-secret", "/v1/models/other", "", http.StatusForbidden, "model_not_allowed"},
		{"expired key", "Bearer llmhop_d-secret", "/", `{"model":"m"}`, http.StatusUnauthorized, "key_expired"},
	}

	for _, c := range cases {
		method := http.MethodPost
		if c.body == "" {
			method = http.MethodGet
		}

		rec := send(t, h, method, c.path, c.body, c.key)

		var got apiError
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || rec.Code != c.status || got.Error.Code != c.code {
			t.Errorf("%s: got status %d and %s", c.name, rec.Code, rec.Body)
		}

		if rec.Code == http.StatusUnauthorized && rec.Header().Get("WWW-Authenticate") != "Bearer" {
			t.Errorf("%s: no Bearer challenge", c.name)
		}
	}

	var list struct {
		Data []modelObject `json:"data"`
	}

	if err := json.Unmarshal(send(t, h, http.MethodGet, "/v1/models", "", "Bearer llmhop_b-secret").Body.Bytes(), &list); err != nil || len(list.Data) != 1 || string(list.Data[0]["id"]) != `"m"` {
		t.Errorf("listed %v, %v", list.Data, err)
	}

	// Bodies pass verbatim, whether routed by their model or their path.
	if rec := send(t, h, http.MethodPost, "/v1/embeddings", `{"model":"m"}`, "Bearer llmhop_a-secret"); rec.Code != http.StatusOK || captured.body != `{"model":"m"}` {
		t.Errorf("got status %d, backend saw %s", rec.Code, captured.body)
	}

	if rec := send(t, h, http.MethodPost, "/llmhop/proxy/detector/detect", `{"text":"x"}`, "Bearer llmhop_a-secret"); rec.Code != http.StatusOK || captured.body != `{"text":"x"}` {
		t.Errorf("got status %d, backend saw %s", rec.Code, captured.body)
	}

	rec := send(t, h, http.MethodPost, "/", `{"model":"m"}`, "Bearer llmhop_a-secret")
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" || rec.Header().Get("X-Ratelimit-Remaining-Requests") != "0" {
		t.Errorf("got status %d and headers %v", rec.Code, rec.Header())
	}
}

// A request of a retired queue pruned meanwhile waits in the queue of a
// model re-added under its name, which its release then keeps.
func TestRetiredQueueRejoins(t *testing.T) {
	l := &Limits{}
	retired := l.queue("m", 1)
	l.retain(&config.Config{})
	replacement := l.queue("m", 1)
	tk := &ticket{client: &client{name: "c", weight: 1, limiters: &limiters{}}}

	if !retired.admit(t.Context(), tk, 0) || tk.queue != replacement {
		t.Fatal("not admitted by the replacement")
	}

	tk.release()

	if l.queues["m"] != replacement {
		t.Error("the replacement was dropped")
	}
}

// Waiting clients take turns by weight, skipping one at its own limit.
func TestFairQueue(t *testing.T) {
	q := (&Limits{}).queue("m", 1)
	newTicket := func(name string, weight float64) *ticket {
		return &ticket{client: &client{name: name, weight: weight, limiters: &limiters{}}}
	}

	held := newTicket("x", 1)
	q.enqueue(held)
	q.dispatch()

	full := newTicket("c", 1)
	full.client.slots = gauge{size: 1, used: 1}
	q.enqueue(full)

	var waiting []*ticket

	for _, client := range []string{"a", "a", "a", "b", "b", "b"} {
		tk := newTicket(client, 1)
		if client == "a" {
			tk.client.weight = 2
		}

		q.enqueue(tk)
		waiting = append(waiting, tk)
	}

	var order string

	for range 6 {
		held.release()

		i := slices.IndexFunc(waiting, func(tk *ticket) bool { return tk.admitted })
		if i < 0 {
			t.Fatalf("nothing admitted after %q", order)
		}

		held = waiting[i]
		waiting = slices.Delete(waiting, i, i+1)
		order += held.client.name
	}

	if order != "abaabb" {
		t.Errorf("admitted %q", order)
	}
}
