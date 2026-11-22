package router

import (
	"mime"
	"net/http"
)

// mediaType returns the media type of a request or response by its header.
func mediaType(h http.Header) string {
	mediaType, _, _ := mime.ParseMediaType(h.Get("Content-Type"))

	return mediaType
}
