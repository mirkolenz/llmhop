package router

import (
	"encoding/json/v2"
	"net/http"
	"strings"
)

// affinity is the key keeping the requests of a conversation on one server.
type affinity struct {
	key   uint64
	keyed bool
}

// affinityOf hashes the first of the sources that a request carries, a
// `header:<name>` or the body's `prompt_cache_key`, which clients set to
// name their conversation, so that its turns reach the server caching their
// common prefix.
func affinityOf(req *http.Request, sources []string, body []byte) affinity {
	for _, source := range sources {
		var value string
		if name, ok := strings.CutPrefix(source, "header:"); ok {
			value = req.Header.Get(name)
		} else {
			value = promptCacheKey(body)
		}

		if value != "" {
			return affinity{key: hashOf(source, value), keyed: true}
		}
	}

	return affinity{}
}

// promptCacheKey reads the `prompt_cache_key` of a JSON body, if it has one.
func promptCacheKey(body []byte) string {
	var request struct {
		PromptCacheKey string `json:"prompt_cache_key"`
	}

	if json.Unmarshal(body, &request) != nil {
		return ""
	}

	return request.PromptCacheKey
}
