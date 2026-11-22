package router

import (
	"net/http"
	"slices"

	"github.com/mirkolenz/llmhop/internal/config"
)

// affinity is the key keeping the requests of a conversation on one server,
// which a pinned one never leaves, since its state lives there.
type affinity struct {
	key    uint64
	keyed  bool
	pinned bool
}

// affinityOf hashes the first of the sources that a request carries, a
// header or a string at a path into its JSON object body o, which clients
// set to name their conversation, so that its turns reach the server caching
// their common prefix. It pins a pinned source and a request continuing a
// stored response of the Responses API.
func affinityOf(req *http.Request, sources []config.AffinitySource, o *object) affinity {
	for _, source := range sources {
		var value string

		if source.Header != "" {
			value = req.Header.Get(source.Header)
		} else {
			value = o.text(source.Body...)
		}

		if value != "" {
			return affinity{
				key:    hashOf(slices.Concat([]string{source.Header}, source.Body, []string{value})...),
				keyed:  true,
				pinned: source.Pinned || o.text("previous_response_id") != "",
			}
		}
	}

	return affinity{}
}
