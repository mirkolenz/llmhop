package router

import "net/http"

// apiError is the OpenAI error envelope:
//
// https://developers.openai.com/api/reference/errors
type apiError struct {
	Error apiErrorBody `json:"error"`
}

type apiErrorBody struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    string `json:"code"`
}

// errorType maps a status to the OpenAI error type.
func errorType(status int) string {
	switch status {
	case http.StatusUnauthorized:
		return "authentication_error"
	case http.StatusNotFound:
		return "not_found_error"
	case http.StatusTooManyRequests:
		return "rate_limit_error"
	case http.StatusServiceUnavailable:
		return "overloaded_error"
	}

	if status < 500 {
		return "invalid_request_error"
	}

	return "server_error"
}

// writeError answers with an OpenAI-shaped JSON error, where code is a short
// snake_case identifier of the failure.
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, jsonBody(apiError{apiErrorBody{Message: message, Type: errorType(status), Code: code}}))
}
