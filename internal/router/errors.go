package router

import (
	"errors"
	"log/slog"
	"net"
	"net/http"
)

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
	case http.StatusForbidden:
		return "permission_error"
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

// notFound answers a path that llmhop does not serve.
func notFound(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotFound, "not_found", "unknown path")
}

var (
	errInvalidJSON      = &apiErrorBody{Code: "invalid_json", Message: "invalid JSON request body"}
	errMissingModel     = &apiErrorBody{Code: "missing_model", Message: "missing model"}
	errInvalidMultipart = &apiErrorBody{Code: "invalid_multipart", Message: "invalid multipart request body or model field"}
	errAliasRewrite     = &apiErrorBody{Code: "unsupported_alias_body", Message: "this alias rewrites the model of JSON bodies only"}
)

// statusClientClosed is nginx's status of a request its client abandoned,
// which only the log and the metrics see.
const statusClientClosed = 499

// proxyError maps a streamed body exceeding the size limit to 413, a client
// gone before the response to 499, a backend exceeding its response timeout
// to 504, and every other upstream failure to 502 like the default
// ReverseProxy handler.
func proxyError(w http.ResponseWriter, req *http.Request, err error) {
	if _, ok := errors.AsType[*http.MaxBytesError](err); ok {
		bodyTooLarge(w)

		return
	}

	if req.Context().Err() != nil {
		w.WriteHeader(statusClientClosed)

		return
	}

	slog.Error("proxy", "id", req.Header.Get(requestIDHeader), "err", err)

	if netErr, ok := errors.AsType[net.Error](err); ok && netErr.Timeout() {
		writeError(w, http.StatusGatewayTimeout, "backend_timeout", "backend response timeout")

		return
	}

	writeError(w, http.StatusBadGateway, "bad_gateway", "backend unreachable")
}
