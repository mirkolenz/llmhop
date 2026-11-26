package telemetry

import "io"

// engineSeries maps the series of vLLM, SGLang and llama.cpp, which name
// the same quantities differently, onto those of llmhop.
var engineSeries = func() map[string]string {
	out := make(map[string]string)

	for series, names := range map[string][]string{
		EngineRunning:               {"vllm:num_requests_running", "sglang:num_running_reqs", "llamacpp:requests_processing"},
		EngineWaiting:               {"vllm:num_requests_waiting", "sglang:num_queue_reqs", "llamacpp:requests_deferred"},
		EngineKVCache:               {"vllm:kv_cache_usage_perc", "sglang:token_usage"},
		EnginePromptTokens:          {"vllm:prompt_tokens_total", "sglang:prompt_tokens_total", "llamacpp:prompt_tokens_total"},
		EngineCachedTokens:          {"vllm:prompt_tokens_cached_total", "sglang:cached_tokens_total", "llamacpp:prompt_tokens_cached_total"},
		EngineGeneratedTokens:       {"vllm:generation_tokens_total", "sglang:generation_tokens_total", "llamacpp:tokens_predicted_total"},
		EngineFirstToken + "_sum":   {"vllm:time_to_first_token_seconds_sum", "sglang:time_to_first_token_seconds_sum"},
		EngineFirstToken + "_count": {"vllm:time_to_first_token_seconds_count", "sglang:time_to_first_token_seconds_count"},
	} {
		for _, name := range names {
			out[name] = series
		}
	}

	return out
}()

// Engine reads the metrics of an engine and maps them onto the series of
// llmhop over its ranks, a share by its maximum and everything else by its
// sum.
func Engine(r io.Reader) (map[string]float64, error) {
	values := make(map[string]float64)
	mapped := func(name []byte) bool {
		_, ok := engineSeries[string(name)]

		return ok
	}

	err := scan(r, mapped, func(s Sample) {
		series := engineSeries[s.Name]
		values[series] = Combine(series, values[series], s.Value)
	})

	return values, err
}
