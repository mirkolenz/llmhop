// Package telemetry is the contract of the metrics of llmhop: the series
// that GET /llmhop/metrics serves, how the series of the engines map onto
// them, and the Prometheus text format that carries them.
package telemetry

import "strings"

// Path is where llmhop serves its metrics.
const Path = "/llmhop/metrics"

// The labels of the series.
const (
	Client = "client"
	Model  = "model"
	Server = "server"
	Status = "status"
	Kind   = "kind"
)

// The kinds of tokens.
const (
	Prompt     = "prompt"
	Completion = "completion"
)

// The series of the requests that llmhop answered, by client, model and
// status, and the histograms of the successful ones sent in full by model,
// of the time to the first byte of the event streams among them, their
// first token, the seconds that the requests of a client held their slots,
// and of the clients with a token limit by model the tokens that their
// responses reported by kind and the successful responses that reported
// none.
const (
	Requests           = "llmhop_requests_total"
	SlotSeconds        = "llmhop_slot_seconds_total"
	Tokens             = "llmhop_tokens_total"
	UnmeteredResponses = "llmhop_unmetered_responses_total"
	RequestDuration    = "llmhop_request_duration_seconds"
	RequestFirstToken  = "llmhop_request_first_token_seconds"
)

// The series of the present state of the models and their servers.
const (
	// QueuedRequests is the requests of a model waiting for their slots.
	QueuedRequests = "llmhop_queued_requests"
	// RunningRequests is the requests of a model holding their slots by
	// client.
	RunningRequests = "llmhop_running_requests"
	// MaxRunningRequests is the size of the slots of a model, absent without
	// a limit.
	MaxRunningRequests = "llmhop_max_running_requests"
	// ServerUp tells whether a server passed its latest probe, absent
	// without a health path.
	ServerUp = "llmhop_server_up"
)

// The series of the limits of the clients, each absent without the limit:
// the size of their slots, and the sizes of their buckets of requests,
// tokens and slot seconds per minute with what remains in them.
const (
	ClientMaxRunningRequests   = "llmhop_client_max_running_requests"
	ClientMaxRequestsPerMinute = "llmhop_client_max_requests_per_minute"
	ClientRemainingRequests    = "llmhop_client_remaining_requests"
	ClientMaxTokensPerMinute   = "llmhop_client_max_tokens_per_minute"
	ClientRemainingTokens      = "llmhop_client_remaining_tokens"
	ClientMaxSlotSeconds       = "llmhop_client_max_slot_seconds_per_minute"
	ClientRemainingSlotSeconds = "llmhop_client_remaining_slot_seconds"
)

// enginePrefix starts the names of the series of the engines.
const enginePrefix = "llmhop_engine_"

// The series that the engines of a server report, by model and server,
// where the time to the first token is a sum and a count as of a histogram.
const (
	// EngineUp tells whether the engines of a server reported their metrics.
	EngineUp              = enginePrefix + "up"
	EngineRunning         = enginePrefix + "running_requests"
	EngineWaiting         = enginePrefix + "waiting_requests"
	EngineKVCache         = enginePrefix + "kv_cache_usage_ratio"
	EnginePromptTokens    = enginePrefix + "prompt_tokens_total"
	EngineCachedTokens    = enginePrefix + "cached_prompt_tokens_total"
	EngineGeneratedTokens = enginePrefix + "generation_tokens_total"
	EngineFirstToken      = enginePrefix + "first_token_seconds"
)

// FromEngine reports whether a series comes from the engines of a server,
// whose scrape EngineUp reports, rather than from llmhop itself.
func FromEngine(name string) bool {
	return strings.HasPrefix(name, enginePrefix)
}

// Counter reports whether a series counts up, by the suffixes of the
// Prometheus conventions.
func Counter(name string) bool {
	return strings.HasSuffix(name, "_total") || strings.HasSuffix(name, "_sum") || strings.HasSuffix(name, "_count")
}

// Ratio reports whether a series is a share, which several sources
// aggregate by its maximum rather than its sum.
func Ratio(name string) bool {
	return strings.HasSuffix(name, "_ratio")
}

// Combine adds the value v of a series to the value a of others of the
// same name, a share by its maximum and everything else by its sum.
func Combine(name string, a, v float64) float64 {
	if Ratio(name) {
		return max(a, v)
	}

	return a + v
}
