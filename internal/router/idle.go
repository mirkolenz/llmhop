package router

import (
	"mime"
	"net/http"
)

// mediaType returns the media type of a response.
func mediaType(resp *http.Response) string {
	mediaType, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))

	return mediaType
}
