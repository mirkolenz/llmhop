package router

import (
	"net/http"

	"github.com/rs/cors"
)

// cors lets the pages of origins, or of every origin with `*`, call the API
// with a bearer token, answering their preflights itself, since these carry
// none. It never allows credentials, so a page can only send a token it was
// given, and leaves trusted sockets alone, whose requests need no token.
func (a *authenticator) cors(origins []string, next http.Handler) http.Handler {
	withCORS := cors.New(cors.Options{
		AllowedOrigins: origins,
		AllowedMethods: []string{http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete},
		// Any header both ways, such as Retry-After or a backend's rate limits,
		// since only the token grants access.
		AllowedHeaders: []string{"*"},
		ExposedHeaders: []string{"*"},
		// Chromium's cap.
		MaxAge: 7200,
	}).Handler(next)

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if _, trusted := a.socketClient(req); trusted {
			next.ServeHTTP(w, req)

			return
		}

		withCORS.ServeHTTP(w, req)
	})
}
