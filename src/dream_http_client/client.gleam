//// Type-safe HTTP client with recording + streaming support
////
//// Gleam doesn't ship with an HTTPS client, so this module wraps
//// [gun](https://github.com/ninenines/gun) (a high-performance Erlang HTTP/1.1
//// and HTTP/2 client) and adds a friendly builder API, streaming helpers,
//// and optional record/playback via `dream_http_client/recorder`.
////
//// ## Quick Example — blocking request
////
//// ### Call an API with a token <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_call_api.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_http_client/client.{add_header, host, path, port, scheme, send}
//// import gleam/http
//// import gleam/result
////
//// pub fn call_api(token: String) -> Result(String, client.SendError) {
////   client.new()
////   |> scheme(http.Http)
////   |> host("localhost")
////   |> port(9876)
////   |> path("/text")
////   |> add_header("Authorization", "Bearer " <> token)
////   |> send()
////   |> result.map(fn(response) { response.body })
//// }
//// ```
////
//// ## Execution modes
////
//// You can execute the same `ClientRequest` in three ways:
////
//// - **Blocking**: `send()` returns the full response body.
//// - **Pull streaming**: `stream_yielder()` returns a `yielder.Yielder` of chunks.
//// - **Callback streaming**: `start_stream()` spawns a stream process and calls
////   your callbacks (`on_stream_*`) as events arrive.
////
//// The “right” choice is mostly about concurrency:
////
//// - Use `send()` for normal JSON APIs.
//// - Use `stream_yielder()` for scripts/one‑offs where blocking is fine.
//// - Use `start_stream()` when you need non‑blocking streaming in OTP code.
////
//// ## Recording and playback
////
//// Attach a recorder with `recorder()` to record real HTTP traffic to disk, or
//// to play back recordings without network calls. All three execution modes
//// (`send()`, `stream_yielder()`, `start_stream()`) fully support both
//// recording and playback.
////
//// ### Record a call <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_record_call.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_http_client/client.{host, path, port, recorder, scheme, send}
//// import dream_http_client/recorder.{directory, mode, start}
//// import gleam/http
//// import gleam/result
//// import gleam/string
////
//// pub fn record_call(mocks_directory: String) -> Result(String, String) {
////   use rec <- result.try(
////     recorder.new()
////     |> directory(mocks_directory)
////     |> mode("record")
////     |> start(),
////   )
////   client.new()
////   |> scheme(http.Http)
////   |> host("localhost")
////   |> port(9876)
////   |> path("/text")
////   |> recorder(rec)
////   |> send()
////   |> result.map(fn(response) { response.body })
////   |> result.map_error(string.inspect)
//// }
//// ```
////
//// ## Inspecting requests
////
//// `ClientRequest` is opaque to keep the public API stable; use the `get_*`
//// functions for logging/testing.
////
//// ### Read the target of a request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_describe_target.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
////
//// ```gleam
//// import dream_http_client/client.{get_host, get_path, host, path}
////
//// pub fn describe_target() -> String {
////   let request = client.new() |> host("api.example.com") |> path("/users/123")
////   "Calling: " <> get_host(request) <> get_path(request)
//// }
//// ```

import dream_http_client/internal
import dream_http_client/recorder
import dream_http_client/recording
import gleam/bytes_tree
import gleam/dynamic/decode as d
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/yielder

/// HTTP header
///
/// Represents a single HTTP header with a name and value. Used throughout the
/// module for type-safe header handling.
///
/// ## Fields
///
/// - `name`: Header name (e.g., "Content-Type", "Authorization")
/// - `value`: Header value (e.g., "application/json", "Bearer token")
///
/// ## Usage
///
/// Headers are constructed automatically by builder functions like `add_header()`,
/// but you'll work with this type when inspecting headers:
///
/// ### Read the first header <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_first_header.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{Header}
///
/// pub fn first_header(request: client.ClientRequest) -> String {
///   case client.get_headers(request) {
///     [Header(name, value), ..] -> name <> ": " <> value
///     [] -> "No headers"
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Header names are case-sensitive as stored, but HTTP treats them case-insensitively
/// - Duplicate header names are allowed (e.g., multiple Set-Cookie headers)
/// - Headers are stored in the order they were added
pub type Header {
  Header(name: String, value: String)
}

/// Complete HTTP response with status code, headers, and body.
///
/// Returned by `send()` for successful HTTP responses (status < 400).
/// Also available inside `ResponseError` for HTTP error responses (status >= 400).
///
/// ## Fields
///
/// - `status`: HTTP status code (e.g. 200, 301, 404, 500)
/// - `headers`: Response headers as `List(Header)` — includes Content-Type,
///   Content-Length, Set-Cookie, and any other headers the server sent
/// - `body`: Complete response body as a UTF-8 string
///
/// ## Example
///
/// ### Match on the response <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_describe_response.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{HttpResponse}
/// import gleam/int
///
/// pub fn describe_response(request: client.ClientRequest) -> String {
///   case client.send(request) {
///     Ok(HttpResponse(status: 200, body: body, ..)) -> "OK: " <> body
///     Ok(HttpResponse(status: status, ..)) -> "Status " <> int.to_string(status)
///     Error(_) -> "Request failed"
///   }
/// }
/// ```
pub type HttpResponse {
  HttpResponse(status: Int, headers: List(Header), body: String)
}

/// Transport-level error from the underlying gun HTTP client.
///
/// Each variant preserves ALL structured information that gun provides for that
/// error class. Use `transport_error_to_string` for human-readable log output,
/// or pattern match on variants for programmatic error handling (retry logic,
/// alerting, circuit breakers).
///
/// ## Variants
///
/// - `StreamReset` — HTTP/2 RST_STREAM frame. The `code` field is the HTTP/2
///   error code as a string (e.g. `"internal_error"`, `"cancel"`,
///   `"refused_stream"`, `"enhance_your_calm"`). The `description` field is
///   gun's human-readable explanation.
///
/// - `Goaway` — HTTP/2 GOAWAY frame. The server is shutting down gracefully.
///   `last_stream_id` indicates the last stream the server will process.
///   `debug_data` may contain additional context from the server.
///
/// - `ConnectionError` — Connection-level protocol error. The `code` field is
///   the error code and `description` is gun's human-readable explanation.
///
/// - `RemoteClosed` — The remote peer closed the connection without sending
///   an explicit error code.
///
/// - `TimedOut` — No response was received within the configured timeout.
///   `timeout_ms` is the value that was configured.
///
/// - `ProcessDown` — The connection or stream owner process died unexpectedly.
///   `reason` describes why the process exited.
///
/// - `ConnectFailed` — Could not establish a connection to the server. Common
///   causes include connection refused (server not running), DNS resolution
///   failure (NXDOMAIN), and TLS handshake errors.
///
/// - `Unexpected` — An error that doesn't match any known pattern. `raw`
///   contains the Erlang term formatted as a string for debugging.
///
/// ## Example
///
/// ### Explain a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_transport_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type TransportError, ConnectFailed, StreamReset, TimedOut,
///   transport_error_to_string,
/// }
/// import gleam/int
///
/// pub fn explain(error: TransportError) -> String {
///   case error {
///     ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
///     TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
///     StreamReset(code: code, description: description) ->
///       "Stream reset: " <> code <> " - " <> description
///     _ -> transport_error_to_string(error)
///   }
/// }
/// ```
pub type TransportError {
  StreamReset(code: String, description: String)
  Goaway(code: String, last_stream_id: Int, debug_data: String)
  ConnectionError(code: String, description: String)
  RemoteClosed
  TimedOut(timeout_ms: Int)
  ProcessDown(reason: String)
  ConnectFailed(reason: String)
  Unexpected(raw: String)
}

/// Failure during streaming, distinguishing HTTP errors from transport errors.
///
/// When a streaming request (`stream_yielder` or `start_stream`) fails, the
/// failure is either an HTTP-level rejection (the server responded with a
/// non-2xx status) or a transport-level error (the connection broke).
///
/// ## Variants
///
/// - `HttpFailure` — The server returned a non-2xx status code before streaming
///   began. The full `HttpResponse` is available including status, headers
///   (useful for `retry-after`, `x-request-id`), and body.
///
/// - `TransportFailure` — A transport-level error occurred during connection
///   or streaming. See `TransportError` for the specific error variants.
///
/// ## Example
///
/// ### Explain a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_stream_failure.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type StreamFailure, ConnectFailed, HttpFailure, TransportFailure,
///   transport_error_to_string,
/// }
/// import gleam/int
///
/// pub fn explain_failure(failure: StreamFailure) -> String {
///   case failure {
///     HttpFailure(response: response) -> "HTTP " <> int.to_string(response.status)
///     TransportFailure(error: ConnectFailed(reason: reason)) ->
///       "Cannot connect: " <> reason
///     TransportFailure(error: error) -> transport_error_to_string(error)
///   }
/// }
/// ```
pub type StreamFailure {
  HttpFailure(response: HttpResponse)
  TransportFailure(error: TransportError)
}

/// Convert a `TransportError` to a human-readable string for logging.
///
/// Produces a single-line summary suitable for log messages. For programmatic
/// error handling, pattern match on the `TransportError` variants instead.
///
/// ## Example
///
/// ### Describe a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_error_to_string.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{ConnectFailed, transport_error_to_string}
///
/// pub fn connect_failed_message() -> String {
///   transport_error_to_string(ConnectFailed(reason: "Connection refused"))
/// }
/// ```
pub fn transport_error_to_string(error: TransportError) -> String {
  case error {
    StreamReset(code: code, description: description) ->
      "Stream reset (" <> code <> "): " <> description
    Goaway(code: code, last_stream_id: last_id, debug_data: debug) ->
      "GOAWAY ("
      <> code
      <> ", last_stream_id="
      <> int.to_string(last_id)
      <> "): "
      <> debug
    ConnectionError(code: code, description: description) ->
      "Connection error (" <> code <> "): " <> description
    RemoteClosed -> "Remote closed connection"
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    ProcessDown(reason: reason) -> "Process down: " <> reason
    ConnectFailed(reason: reason) -> "Connection failed: " <> reason
    Unexpected(raw: raw) -> "Unexpected error: " <> raw
  }
}

/// Convert a `StreamFailure` to a human-readable string for logging.
///
/// Produces a single-line summary suitable for log messages. For programmatic
/// error handling, pattern match on the `StreamFailure` variants instead.
///
/// ## Example
///
/// ### Describe a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_stream_failure_to_string.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   TimedOut, TransportFailure, stream_failure_to_string,
/// }
///
/// pub fn timeout_message() -> String {
///   stream_failure_to_string(TransportFailure(error: TimedOut(timeout_ms: 5000)))
/// }
/// ```
pub fn stream_failure_to_string(failure: StreamFailure) -> String {
  case failure {
    HttpFailure(response: response) ->
      "HTTP " <> int.to_string(response.status) <> ": " <> response.body
    TransportFailure(error: error) -> transport_error_to_string(error)
  }
}

/// Error types returned by `send()`.
///
/// ## Variants
///
/// - `ResponseError(response: HttpResponse)` — the server responded with a
///   4xx or 5xx status code. The full `HttpResponse` is available with status,
///   headers, and body. The body typically contains error details (e.g. JSON
///   error messages from an API, or HTML error pages).
///
/// - `RequestError(error: TransportError)` — the request could not be
///   completed due to a transport-level failure. Pattern match on the
///   `TransportError` for the specific cause, or use
///   `transport_error_to_string` for logging.
///
/// ## Example
///
/// ### Handle every send error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_send_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   ConnectFailed, RequestError, ResponseError, transport_error_to_string,
/// }
/// import gleam/int
///
/// pub fn send_and_describe(request: client.ClientRequest) -> String {
///   case client.send(request) {
///     Ok(response) -> "Got " <> int.to_string(response.status)
///     Error(ResponseError(response: response)) ->
///       "HTTP " <> int.to_string(response.status)
///     Error(RequestError(error: ConnectFailed(reason: reason))) ->
///       "Cannot connect: " <> reason
///     Error(RequestError(error: error)) ->
///       "Failed: " <> transport_error_to_string(error)
///   }
/// }
/// ```
pub type SendError {
  ResponseError(response: HttpResponse)
  RequestError(error: TransportError)
}

/// Per-request protocol preference for HTTP connections.
///
/// Controls which HTTP protocol version gun negotiates when opening a connection.
/// The connection manager uses this to set gun's `protocols` option and, for TLS
/// connections, to align ALPN advertisement accordingly.
///
/// ## Variants
///
/// - `Http1Only` — HTTP/1.1 only. Maps to gun `protocols => [http]`.
///
/// - `Http2Only` — HTTP/2 only. For cleartext (TCP) connections this enables
///   h2c "prior knowledge" mode per RFC 7540 Section 3.4 — gun speaks HTTP/2
///   directly without an upgrade dance. For TLS connections this advertises
///   only `h2` via ALPN.
///
/// - `Http2Preferred` — Prefer HTTP/2, fall back to HTTP/1.1. Maps to gun
///   `protocols => [http2, http]`. This is the default for TLS connections
///   (ALPN negotiation). For TCP, this uses the HTTP/1.1 Upgrade mechanism
///   which most servers do not support — use `Http2Only` for cleartext
///   HTTP/2 instead.
///
/// ## Example
///
/// ### Use HTTP/2 only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_http2_only.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{Http2Only}
/// import gleam/http
///
/// pub fn http2_only_request() -> client.ClientRequest {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("internal-service.local")
///   |> client.protocols(Http2Only)
/// }
/// ```
pub type Protocols {
  Http1Only
  Http2Only
  Http2Preferred
}

/// Minimum log level for dream_http_client's internal log output.
///
/// Controls which log messages are emitted by the library's connection manager
/// and HTTP shim. Uses OTP's `logger:set_module_level/2` under the hood, so
/// filtering is scoped to dream's own modules and does not affect the rest of
/// your application.
///
/// ## Variants
///
/// - `LogDebug` — All messages including debug-level detail.
/// - `LogInfo` — Informational messages and above (default). Includes graceful
///   connection closures.
/// - `LogWarning` — Warnings and above only. Unexpected disconnects,
///   decompression failures, unrecognized content encodings.
/// - `LogError` — Errors only.
/// - `LogNone` — Suppress all log output from dream_http_client.
///
/// ## Example
///
/// ### Log warnings only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{LogWarning}
///
/// pub fn warnings_only() -> Nil {
///   client.transport_config()
///   |> client.log_level(LogWarning)
///   |> client.configure_transport()
/// }
/// ```
pub type LogLevel {
  LogDebug
  LogInfo
  LogWarning
  LogError
  LogNone
}

/// HTTP client request configuration
///
/// Represents a complete HTTP request with all its components. Use the builder
/// pattern with functions like `host()`, `path()`, `method()`, etc. to configure
/// the request, then execute it with `send()`, `stream_yielder()`, or
/// `start_stream()` depending on whether you want a
/// blocking, pull-streaming, or callback-streaming API.
///
/// ## Fields
///
/// - `method`: The HTTP method (GET, POST, etc.)
/// - `scheme`: The protocol (HTTP or HTTPS)
/// - `host`: The server hostname
/// - `port`: Optional port number (defaults to 80 for HTTP, 443 for HTTPS)
/// - `path`: The request path (e.g., "/api/users")
/// - `query`: Optional query string (e.g., "?page=1&limit=10")
/// - `headers`: List of header name-value pairs
/// - `body`: The request body as a string
/// - `timeout`: Optional timeout in milliseconds (defaults to 30000ms)
/// - `recorder`: Optional recorder for request/response recording and playback
///
/// The type is opaque to ensure API stability. Use `new` with builder functions
/// to construct requests, and the getter functions to inspect request properties.
pub opaque type ClientRequest {
  ClientRequest(
    method: http.Method,
    scheme: http.Scheme,
    host: String,
    port: Option(Int),
    path: String,
    query: Option(String),
    headers: List(Header),
    body: String,
    timeout: Option(Int),
    connect_timeout: Option(Int),
    auto_redirect: Option(Bool),
    recorder: Option(recorder.Recorder),
    on_stream_start: Option(fn(List(Header)) -> Nil),
    on_stream_chunk: Option(fn(BitArray) -> Nil),
    on_stream_end: Option(fn(List(Header)) -> Nil),
    on_stream_error: Option(fn(StreamFailure) -> Nil),
    protocols: Option(Protocols),
    certificate_authority_file: Option(String),
  )
}

/// Default client request configuration
///
/// Creates a new `ClientRequest` with sensible defaults:
/// - Method: GET
/// - Scheme: HTTPS
/// - Host: "localhost"
/// - Port: None (uses default for scheme)
/// - Path: "" (empty)
/// - Query: None
/// - Headers: [] (empty)
/// - Body: "" (empty)
/// - Timeout: None (uses default 30000ms)
///
/// Use this as the starting point for building requests with the builder pattern.
///
/// ## Example
///
/// ### Build a request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_new.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{host, method, new, path}
/// import gleam/http.{Get}
///
/// pub fn user_request() -> client.ClientRequest {
///   new()
///   |> host("api.example.com")
///   |> path("/users/123")
///   |> method(Get)
/// }
/// ```
pub fn new() -> ClientRequest {
  ClientRequest(
    method: http.Get,
    scheme: http.Https,
    host: "localhost",
    port: None,
    path: "",
    query: None,
    headers: [],
    body: "",
    timeout: None,
    connect_timeout: None,
    auto_redirect: None,
    recorder: None,
    on_stream_start: None,
    on_stream_chunk: None,
    on_stream_end: None,
    on_stream_error: None,
    protocols: None,
    certificate_authority_file: None,
  )
}

/// Set the HTTP method for the request
///
/// Configures the HTTP method (GET, POST, PUT, DELETE, etc.) for the request.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `method_value`: The HTTP method to use
///
/// ## Returns
///
/// A new `ClientRequest` with the method updated.
///
/// ## Example
///
/// ### Set the method <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_method.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
///
/// pub fn post_request() -> client.ClientRequest {
///   client.new()
///   |> client.method(http.Post)
/// }
/// ```
pub fn method(
  client_request: ClientRequest,
  method_value: http.Method,
) -> ClientRequest {
  ClientRequest(..client_request, method: method_value)
}

/// Set the scheme (protocol) for the request
///
/// Configures whether to use HTTP or HTTPS. Defaults to HTTPS for security.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `scheme_value`: The protocol scheme (`http.Http` or `http.Https`)
///
/// ## Returns
///
/// A new `ClientRequest` with the scheme updated.
///
/// ## Example
///
/// ### Set the scheme <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_scheme.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
///
/// pub fn plain_http_request() -> client.ClientRequest {
///   client.new()
///   |> client.scheme(http.Http)
/// }
/// ```
pub fn scheme(
  client_request: ClientRequest,
  scheme_value: http.Scheme,
) -> ClientRequest {
  ClientRequest(..client_request, scheme: scheme_value)
}

/// Set the host for the request
///
/// Sets the server hostname or IP address. This is required for all requests.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `host_value`: The hostname (e.g., "api.example.com" or "192.168.1.1")
///
/// ## Returns
///
/// A new `ClientRequest` with the host updated.
///
/// ## Example
///
/// ### Set the host <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_host.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn api_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("api.example.com")
/// }
/// ```
pub fn host(
  client_request: ClientRequest,
  host_value: String,
) -> ClientRequest {
  ClientRequest(..client_request, host: host_value)
}

/// Set the port for the request
///
/// Sets a custom port number. If not set, defaults to 80 for HTTP and 443
/// for HTTPS. Only set this if you're using a non-standard port.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `port_value`: The port number (e.g., 8080, 3000)
///
/// ## Returns
///
/// A new `ClientRequest` with the port updated.
///
/// ## Example
///
/// ### Set the port <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_port.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn local_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("localhost")
///   |> client.port(3000)
/// }
/// ```
pub fn port(client_request: ClientRequest, port_value: Int) -> ClientRequest {
  ClientRequest(..client_request, port: option.Some(port_value))
}

/// Set the path for the request
///
/// Sets the request path. Should start with "/" for absolute paths.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `path_value`: The path (e.g., "/api/users" or "/api/users/123")
///
/// ## Returns
///
/// A new `ClientRequest` with the path updated.
///
/// ## Example
///
/// ### Set the path <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_path.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn user_request() -> client.ClientRequest {
///   client.new()
///   |> client.path("/api/users/123")
/// }
/// ```
pub fn path(
  client_request: ClientRequest,
  path_value: String,
) -> ClientRequest {
  ClientRequest(..client_request, path: path_value)
}

/// Set the query string for the request
///
/// Sets the query string portion of the URL. Do not include the leading "?".
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `query_value`: The query string (e.g., "page=1&limit=10")
///
/// ## Returns
///
/// A new `ClientRequest` with the query string updated.
///
/// ## Example
///
/// ### Set the query string <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn first_page_request() -> client.ClientRequest {
///   client.new()
///   |> client.path("/api/users")
///   |> client.query("page=1&limit=10")
/// }
/// ```
pub fn query(
  client_request: ClientRequest,
  query_value: String,
) -> ClientRequest {
  ClientRequest(..client_request, query: option.Some(query_value))
}

/// Set the headers for the request
///
/// Replaces all existing headers with the provided list. Use `add_header()`
/// to add a single header without replacing existing ones.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `headers_value`: List of header tuples `#(name, value)`
///
/// ## Returns
///
/// A new `ClientRequest` with headers replaced.
///
/// ## Example
///
/// ### Set the headers <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_headers.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{Header}
///
/// pub fn json_api_request(token: String) -> client.ClientRequest {
///   client.new()
///   |> client.headers([
///     Header("Authorization", "Bearer " <> token),
///     Header("Content-Type", "application/json"),
///   ])
/// }
/// ```
pub fn headers(
  client_request: ClientRequest,
  headers_value: List(Header),
) -> ClientRequest {
  ClientRequest(..client_request, headers: headers_value)
}

/// Set the body for the request
///
/// Sets the request body as a string. Typically used for POST, PUT, and PATCH
/// requests. For JSON, serialize your data first.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `body_value`: The request body as a string
///
/// ## Returns
///
/// A new `ClientRequest` with the body updated.
///
/// ## Example
///
/// ### Send a JSON body <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_body.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/json
///
/// pub fn create_user_request() -> client.ClientRequest {
///   let json_body =
///     json.object([
///       #("name", json.string("Alice")),
///       #("email", json.string("alice@example.com")),
///     ])
///
///   client.new()
///   |> client.method(http.Post)
///   |> client.body(json.to_string(json_body))
/// }
/// ```
pub fn body(
  client_request: ClientRequest,
  body_value: String,
) -> ClientRequest {
  ClientRequest(..client_request, body: body_value)
}

/// Set the recorder for the request
///
/// Attaches a recorder to the request for recording or playback.
/// The recorder must be started with `recorder.start()` before use.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `recorder_value`: The recorder to attach
///
/// ## Returns
///
/// A new `ClientRequest` with the recorder attached.
///
/// ## Example
///
/// ### Attach a recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{host, recorder}
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/result
///
/// pub fn recorded_request(
///   mocks_directory: String,
/// ) -> Result(client.ClientRequest, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///   client.new() |> host("api.example.com") |> recorder(rec)
/// }
/// ```
pub fn recorder(
  client_request: ClientRequest,
  recorder_value: recorder.Recorder,
) -> ClientRequest {
  ClientRequest(..client_request, recorder: Some(recorder_value))
}

/// Set the timeout for the request in milliseconds
///
/// Sets how long to wait for a response before timing out. If not set,
/// defaults to 30000ms (30 seconds).
///
/// ## Parameters
///
/// - `timeout_ms`: Timeout duration in milliseconds
///
/// ## Example
///
/// ### Set a timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{host, timeout}
///
/// pub fn slow_request() -> client.ClientRequest {
///   client.new()
///   |> host("slow-api.example.com")
///   |> timeout(60_000)
/// }
/// ```
pub fn timeout(
  client_request: ClientRequest,
  timeout_ms: Int,
) -> ClientRequest {
  ClientRequest(..client_request, timeout: option.Some(timeout_ms))
}

/// Set TCP connection timeout in milliseconds
///
/// Controls how long to wait for the TCP connection to be established.
/// This is separate from the request `timeout()`, which controls the total
/// time for the entire HTTP request/response cycle.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `ms`: Connection timeout in milliseconds (default: 15000)
///
/// ## Example
///
/// ### Set a connect timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_connect_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn fetch_with_connect_timeout() -> Result(String, client.SendError) {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/text")
///   |> client.connect_timeout(5000)
///   |> client.send()
///   |> result.map(fn(response) { response.body })
/// }
/// ```
pub fn connect_timeout(
  client_request: ClientRequest,
  ms: Int,
) -> ClientRequest {
  ClientRequest(..client_request, connect_timeout: option.Some(ms))
}

/// Set whether HTTP redirects are followed automatically
///
/// When enabled (default), the client follows 3xx redirects automatically
/// and returns the final response. When disabled, the 3xx response is
/// returned as `Ok(HttpResponse(...))` with the redirect status code and
/// Location header visible, allowing manual redirect handling.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `enabled`: Whether to follow redirects automatically (default: True)
///
/// ## Example
///
/// ### Inspect a redirect <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_auto_redirect.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn redirect_status() -> Result(Int, client.SendError) {
///   // Disable auto-redirect to inspect the 3xx response
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/redirect/301")
///   |> client.auto_redirect(False)
///   |> client.send()
///   |> result.map(fn(response) { response.status })
/// }
/// ```
pub fn auto_redirect(
  client_request: ClientRequest,
  enabled: Bool,
) -> ClientRequest {
  ClientRequest(..client_request, auto_redirect: option.Some(enabled))
}

/// Set the protocol preference for the connection.
///
/// Controls which HTTP protocol version gun negotiates when opening a connection.
/// When not set, defaults to HTTP/2 preferred (via ALPN) for HTTPS connections
/// and HTTP/1.1 only for HTTP connections.
///
/// For HTTP/2 over cleartext (h2c), use `Http2Only` with `scheme(http.Http)`:
///
/// ### Use HTTP/2 only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_http2_only.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{Http2Only}
/// import gleam/http
///
/// pub fn http2_only_request() -> client.ClientRequest {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("internal-service.local")
///   |> client.protocols(Http2Only)
/// }
/// ```
pub fn protocols(
  client_request: ClientRequest,
  preference: Protocols,
) -> ClientRequest {
  ClientRequest(..client_request, protocols: option.Some(preference))
}

/// Trust only the certificate authorities in a PEM file for this request
///
/// Over HTTPS, the client checks the server's certificate against the system
/// certificate authorities. With this setting, the request trusts the
/// certificate authorities in `path` in their place, the same as
/// `curl --cacert`. Use it for services with a private certificate
/// authority, and for test servers with their own certificate.
///
/// This setting wins over `default_certificate_authority_file()`. Requests
/// with different settings never share a connection. Plain HTTP requests
/// ignore it.
///
/// If the file cannot be read, the request fails with a transport error.
///
/// ## Example
///
/// ### Read the request settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn internal_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("internal.example.com")
///   |> client.certificate_authority_file("certs/internal-ca.pem")
///   |> client.connect_timeout(2000)
///   |> client.auto_redirect(False)
/// }
///
/// pub fn request_settings(
///   request: client.ClientRequest,
/// ) -> #(Option(String), Option(Int), Option(Bool)) {
///   #(
///     client.get_certificate_authority_file(request),
///     client.get_connect_timeout(request),
///     client.get_auto_redirect(request),
///   )
/// }
/// ```
pub fn certificate_authority_file(
  client_request: ClientRequest,
  path: String,
) -> ClientRequest {
  ClientRequest(..client_request, certificate_authority_file: option.Some(path))
}

// ============================================================================
// Transport Configuration
// ============================================================================

/// Configuration for the HTTP transport layer
///
/// Controls connection pool behavior, gun client options, and log verbosity.
/// These settings are global and affect all subsequent HTTP requests.
/// Gun negotiates HTTP/2 automatically for TLS connections via ALPN,
/// falling back to HTTP/1.1. For cleartext (TCP) connections, the default
/// is HTTP/1.1 only; use `protocols(Http2Only)` on `ClientRequest` for
/// h2c (HTTP/2 over cleartext) per-request.
///
/// Create with `transport_config()`, configure with builder functions,
/// and apply with `configure_transport()`.
///
/// ## Example
///
/// ### Configure the pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_config.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn configure_pool() -> Nil {
///   client.transport_config()
///   |> client.max_connections(200)
///   |> client.idle_timeout(120_000)
///   |> client.configure_transport()
/// }
/// ```
pub opaque type TransportConfig {
  TransportConfig(
    max_connections: Int,
    idle_timeout: Int,
    default_connect_timeout: Int,
    domain_lookup_timeout: Int,
    tls_handshake_timeout: Int,
    retry: Int,
    retry_timeout: Int,
    keepalive: Int,
    keepalive_tolerance: Int,
    max_concurrent_streams: Int,
    initial_connection_window_size: Int,
    initial_stream_window_size: Int,
    closing_timeout: Int,
    log_level: LogLevel,
    default_certificate_authority_file: Option(String),
  )
}

/// Create a transport configuration with default values
///
/// Returns a `TransportConfig` with sensible defaults:
/// - max_connections: 50 (TCP connections per host)
/// - idle_timeout: 60_000ms (close idle connections after 60s)
/// - default_connect_timeout: 15_000ms (TCP connection timeout)
/// - domain_lookup_timeout: 5_000ms (DNS resolution timeout)
/// - tls_handshake_timeout: 10_000ms (TLS negotiation timeout)
/// - retry: 3 (reconnection attempts)
/// - retry_timeout: 1_000ms (between retries)
/// - keepalive: 30_000ms (HTTP/2 ping interval)
/// - keepalive_tolerance: 3 (unack'd pings before disconnect)
/// - max_concurrent_streams: 100 (HTTP/2 streams per connection)
/// - initial_connection_window_size: 65_535 (HTTP/2 connection flow control)
/// - initial_stream_window_size: 65_535 (HTTP/2 per-stream flow control)
/// - closing_timeout: 15_000ms (graceful shutdown wait)
/// - log_level: LogInfo (minimum severity for dream log output)
/// - default_certificate_authority_file: None (trust the system certificate
///   authorities over TLS)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn transport_config() -> TransportConfig {
  TransportConfig(
    max_connections: 50,
    idle_timeout: 60_000,
    default_connect_timeout: 15_000,
    domain_lookup_timeout: 5000,
    tls_handshake_timeout: 10_000,
    retry: 3,
    retry_timeout: 1000,
    keepalive: 30_000,
    keepalive_tolerance: 3,
    max_concurrent_streams: 100,
    initial_connection_window_size: 65_535,
    initial_stream_window_size: 65_535,
    closing_timeout: 15_000,
    log_level: LogInfo,
    default_certificate_authority_file: None,
  )
}

/// Set maximum TCP connections per host
///
/// Controls how many simultaneous TCP connections can be open to a single
/// host. With HTTP/2, a single connection supports multiplexed streams,
/// so fewer connections are needed than with HTTP/1.1.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `count`: Maximum connections per host (default: 50)
///
/// ## Example
///
/// ### Allow more connections <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_max_connections.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn allow_more_connections() -> Nil {
///   client.transport_config()
///   |> client.max_connections(200)
///   |> client.configure_transport()
/// }
/// ```
pub fn max_connections(config: TransportConfig, count: Int) -> TransportConfig {
  TransportConfig(..config, max_connections: count)
}

/// Set idle connection timeout in milliseconds
///
/// Controls how long an idle connection is held open before being closed.
/// Longer timeouts improve connection reuse but consume resources.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: Idle timeout in milliseconds (default: 60_000)
///
/// ## Example
///
/// ### Keep idle connections longer <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_idle_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn keep_idle_connections() -> Nil {
///   client.transport_config()
///   |> client.idle_timeout(120_000)
///   |> client.configure_transport()
/// }
/// ```
pub fn idle_timeout(config: TransportConfig, ms: Int) -> TransportConfig {
  TransportConfig(..config, idle_timeout: ms)
}

/// Set default TCP connection timeout in milliseconds
///
/// The default timeout for establishing a TCP connection when not
/// overridden per-request via `connect_timeout()`.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: Connection timeout in milliseconds (default: 15_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn default_connect_timeout(
  config: TransportConfig,
  ms: Int,
) -> TransportConfig {
  TransportConfig(..config, default_connect_timeout: ms)
}

/// Set DNS resolution timeout in milliseconds
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: DNS lookup timeout in milliseconds (default: 5_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn domain_lookup_timeout(
  config: TransportConfig,
  ms: Int,
) -> TransportConfig {
  TransportConfig(..config, domain_lookup_timeout: ms)
}

/// Set TLS handshake timeout in milliseconds
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: TLS negotiation timeout in milliseconds (default: 10_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn tls_handshake_timeout(
  config: TransportConfig,
  ms: Int,
) -> TransportConfig {
  TransportConfig(..config, tls_handshake_timeout: ms)
}

/// Set number of reconnection attempts
///
/// How many times gun will attempt to reconnect after a connection is lost.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `count`: Number of retry attempts (default: 3)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn retry(config: TransportConfig, count: Int) -> TransportConfig {
  TransportConfig(..config, retry: count)
}

/// Set delay between reconnection attempts in milliseconds
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: Delay between retries in milliseconds (default: 1_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn retry_timeout(config: TransportConfig, ms: Int) -> TransportConfig {
  TransportConfig(..config, retry_timeout: ms)
}

/// Set HTTP/2 keepalive ping interval in milliseconds
///
/// How often to send HTTP/2 PING frames to keep the connection alive
/// and detect dead connections.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: Ping interval in milliseconds (default: 30_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn keepalive(config: TransportConfig, ms: Int) -> TransportConfig {
  TransportConfig(..config, keepalive: ms)
}

/// Set HTTP/2 keepalive tolerance
///
/// How many unacknowledged PING frames are allowed before the connection
/// is considered dead and closed.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `count`: Max unacknowledged pings (default: 3)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn keepalive_tolerance(
  config: TransportConfig,
  count: Int,
) -> TransportConfig {
  TransportConfig(..config, keepalive_tolerance: count)
}

/// Set maximum concurrent HTTP/2 streams per connection
///
/// Controls the maximum number of concurrent streams allowed on a single
/// HTTP/2 connection. Increase for highly concurrent workloads.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `count`: Max concurrent streams (default: 100)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn max_concurrent_streams(
  config: TransportConfig,
  count: Int,
) -> TransportConfig {
  TransportConfig(..config, max_concurrent_streams: count)
}

/// Set HTTP/2 connection-level flow control window size
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `size`: Window size in bytes (default: 65_535)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn initial_connection_window_size(
  config: TransportConfig,
  size: Int,
) -> TransportConfig {
  TransportConfig(..config, initial_connection_window_size: size)
}

/// Set HTTP/2 per-stream flow control window size
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `size`: Window size in bytes (default: 65_535)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn initial_stream_window_size(
  config: TransportConfig,
  size: Int,
) -> TransportConfig {
  TransportConfig(..config, initial_stream_window_size: size)
}

/// Set graceful shutdown timeout in milliseconds
///
/// How long to wait for in-flight requests to complete when closing
/// a connection.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `ms`: Shutdown wait in milliseconds (default: 15_000)
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn closing_timeout(config: TransportConfig, ms: Int) -> TransportConfig {
  TransportConfig(..config, closing_timeout: ms)
}

/// Set the minimum log level for dream_http_client's internal log output
///
/// Controls which log messages are emitted by the library's connection manager
/// and HTTP shim. Filtering is scoped to dream's own modules via OTP's
/// `logger:set_module_level/2` and does not affect the rest of your application.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `level`: Minimum log level (default: `LogInfo`)
///
/// ## Example
///
/// ### Log warnings only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{LogWarning}
///
/// pub fn warnings_only() -> Nil {
///   client.transport_config()
///   |> client.log_level(LogWarning)
///   |> client.configure_transport()
/// }
/// ```
pub fn log_level(config: TransportConfig, level: LogLevel) -> TransportConfig {
  TransportConfig(..config, log_level: level)
}

/// Get the configured maximum TCP connections per host
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_max_connections(config: TransportConfig) -> Int {
  config.max_connections
}

/// Get the configured idle connection timeout in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_idle_timeout(config: TransportConfig) -> Int {
  config.idle_timeout
}

/// Get the configured default TCP connection timeout in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_default_connect_timeout(config: TransportConfig) -> Int {
  config.default_connect_timeout
}

/// Get the configured DNS resolution timeout in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_domain_lookup_timeout(config: TransportConfig) -> Int {
  config.domain_lookup_timeout
}

/// Get the configured TLS handshake timeout in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_tls_handshake_timeout(config: TransportConfig) -> Int {
  config.tls_handshake_timeout
}

/// Get the configured number of reconnection attempts
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_retry(config: TransportConfig) -> Int {
  config.retry
}

/// Get the configured delay between reconnection attempts in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_retry_timeout(config: TransportConfig) -> Int {
  config.retry_timeout
}

/// Get the configured HTTP/2 keepalive ping interval in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_keepalive(config: TransportConfig) -> Int {
  config.keepalive
}

/// Get the configured HTTP/2 keepalive tolerance
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_keepalive_tolerance(config: TransportConfig) -> Int {
  config.keepalive_tolerance
}

/// Get the configured maximum concurrent HTTP/2 streams per connection
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_max_concurrent_streams(config: TransportConfig) -> Int {
  config.max_concurrent_streams
}

/// Get the configured HTTP/2 connection-level flow control window size
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_initial_connection_window_size(config: TransportConfig) -> Int {
  config.initial_connection_window_size
}

/// Get the configured HTTP/2 per-stream flow control window size
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_initial_stream_window_size(config: TransportConfig) -> Int {
  config.initial_stream_window_size
}

/// Get the configured graceful shutdown timeout in milliseconds
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_closing_timeout(config: TransportConfig) -> Int {
  config.closing_timeout
}

/// Set the certificate authorities that every HTTPS request trusts
///
/// By default, the client checks servers' certificates against the system
/// certificate authorities. With this setting, every request trusts the
/// certificate authorities in the PEM file at `path` in their place, unless
/// the request sets its own with `certificate_authority_file()`.
///
/// ## Example
///
/// ### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn tuned_transport() -> client.TransportConfig {
///   client.transport_config()
///   |> client.max_connections(100)
///   |> client.idle_timeout(30_000)
///   |> client.default_connect_timeout(5000)
///   |> client.domain_lookup_timeout(2000)
///   |> client.tls_handshake_timeout(5000)
///   |> client.retry(1)
///   |> client.retry_timeout(500)
///   |> client.keepalive(10_000)
///   |> client.keepalive_tolerance(3)
///   |> client.max_concurrent_streams(200)
///   |> client.initial_connection_window_size(1_048_576)
///   |> client.initial_stream_window_size(262_144)
///   |> client.closing_timeout(5000)
///   |> client.default_certificate_authority_file("certs/ca.pem")
/// }
/// ```
pub fn default_certificate_authority_file(
  config: TransportConfig,
  path: String,
) -> TransportConfig {
  TransportConfig(
    ..config,
    default_certificate_authority_file: option.Some(path),
  )
}

/// Get the client-wide certificate authority file, if one is set
///
/// Returns `None` when requests trust the system certificate authorities.
///
/// ## Example
///
/// ### Read the transport settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_getters.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
///   [
///     client.get_max_connections(config),
///     client.get_idle_timeout(config),
///     client.get_default_connect_timeout(config),
///     client.get_domain_lookup_timeout(config),
///     client.get_tls_handshake_timeout(config),
///     client.get_retry(config),
///     client.get_retry_timeout(config),
///     client.get_keepalive(config),
///     client.get_keepalive_tolerance(config),
///     client.get_max_concurrent_streams(config),
///     client.get_initial_connection_window_size(config),
///     client.get_initial_stream_window_size(config),
///     client.get_closing_timeout(config),
///   ]
/// }
///
/// pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
///   client.get_default_certificate_authority_file(config)
/// }
/// ```
pub fn get_default_certificate_authority_file(
  config: TransportConfig,
) -> Option(String) {
  config.default_certificate_authority_file
}

/// Get the configured minimum log level
///
/// Returns the `LogLevel` that controls which internal log messages are emitted.
/// Only messages at this level or above are output.
///
/// ## Example
///
/// ### Read the log level <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn default_log_level() -> client.LogLevel {
///   client.transport_config()
///   |> client.get_log_level()
/// }
/// ```
pub fn get_log_level(config: TransportConfig) -> LogLevel {
  config.log_level
}

/// Apply transport configuration to the HTTP client
///
/// Stores transport settings for use by all subsequent HTTP requests.
/// Call this once during application startup. Can be called again to
/// update settings at runtime.
///
/// ## Example
///
/// ### Allow more connections <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_max_connections.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn allow_more_connections() -> Nil {
///   client.transport_config()
///   |> client.max_connections(200)
///   |> client.configure_transport()
/// }
/// ```
pub fn configure_transport(config: TransportConfig) -> Nil {
  configure_transport_ffi(config)
}

@external(erlang, "dream_http_shim", "configure_transport")
fn configure_transport_ffi(config: TransportConfig) -> Nil

/// Set callback for stream start event
///
/// Sets a function to be called when a stream starts and headers are received.
/// Optional - if not set, stream start is ignored.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `callback`: Function called with response headers when stream starts
///
/// ## Example
///
/// ### Count the response headers <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_start.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/erlang/process.{type Subject}
/// import gleam/http
/// import gleam/list
///
/// pub fn report_header_count(
///   reply_to: Subject(Int),
/// ) -> Result(client.StreamHandle, String) {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/stream/fast")
///   |> client.on_stream_start(fn(headers) {
///     process.send(reply_to, list.length(headers))
///   })
///   |> client.start_stream()
/// }
/// ```
pub fn on_stream_start(
  client_request: ClientRequest,
  callback: fn(List(Header)) -> Nil,
) -> ClientRequest {
  ClientRequest(..client_request, on_stream_start: Some(callback))
}

/// Set callback for stream chunk event
///
/// Sets a function to be called for each data chunk received from the stream.
/// This is where you process the actual response data.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `callback`: Function called with each chunk of data
///
/// ## Example
///
/// ### Forward each chunk <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_chunk.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/bit_array
/// import gleam/erlang/process.{type Subject}
/// import gleam/http
/// import gleam/result
///
/// pub fn forward_chunks(
///   reply_to: Subject(String),
/// ) -> Result(client.StreamHandle, String) {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/stream/fast")
///   |> client.on_stream_chunk(fn(data) {
///     let text = bit_array.to_string(data) |> result.unwrap("<binary>")
///     process.send(reply_to, text)
///   })
///   |> client.start_stream()
/// }
/// ```
pub fn on_stream_chunk(
  client_request: ClientRequest,
  callback: fn(BitArray) -> Nil,
) -> ClientRequest {
  ClientRequest(..client_request, on_stream_chunk: Some(callback))
}

/// Set callback for stream end event
///
/// Sets a function to be called when a stream completes successfully.
/// Optional - if not set, stream completion is ignored.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `callback`: Function called with trailing headers when stream completes
///
/// ## Example
///
/// ### Report the end of a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_end.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/erlang/process.{type Subject}
/// import gleam/http
///
/// pub fn report_end(
///   reply_to: Subject(String),
/// ) -> Result(client.StreamHandle, String) {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/stream/fast")
///   |> client.on_stream_end(fn(_headers) {
///     process.send(reply_to, "Stream completed")
///   })
///   |> client.start_stream()
/// }
/// ```
pub fn on_stream_end(
  client_request: ClientRequest,
  callback: fn(List(Header)) -> Nil,
) -> ClientRequest {
  ClientRequest(..client_request, on_stream_end: Some(callback))
}

/// Set callback for stream error event
///
/// Sets a function to be called if the stream fails with an error.
/// The callback receives a `StreamFailure` which distinguishes HTTP failures
/// (non-2xx response) from transport failures (connection errors, timeouts).
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `callback`: Function called with a `StreamFailure` if stream fails
///
/// ## Example
///
/// ### Report a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/erlang/process.{type Subject}
/// import gleam/http
/// import gleam/int
///
/// pub fn report_failure(
///   reply_to: Subject(String),
/// ) -> Result(client.StreamHandle, String) {
///   client.new()
///   |> client.scheme(http.Http)
///   |> client.host("localhost")
///   |> client.port(9876)
///   |> client.path("/status/500")
///   |> client.on_stream_error(fn(failure) {
///     case failure {
///       client.HttpFailure(response: response) ->
///         process.send(reply_to, "HTTP " <> int.to_string(response.status))
///       client.TransportFailure(error: error) ->
///         process.send(
///           reply_to,
///           "Transport: " <> client.transport_error_to_string(error),
///         )
///     }
///   })
///   |> client.start_stream()
/// }
/// ```
pub fn on_stream_error(
  client_request: ClientRequest,
  callback: fn(StreamFailure) -> Nil,
) -> ClientRequest {
  ClientRequest(..client_request, on_stream_error: Some(callback))
}

/// Add a header to the request
///
/// Adds a single header to the existing headers list without replacing them.
/// The new header is prepended to the list, so it will take precedence if
/// there's a duplicate header name.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `name`: The header name (e.g., "Authorization", "Content-Type")
/// - `value`: The header value
///
/// ## Returns
///
/// A new `ClientRequest` with the header added.
///
/// ## Example
///
/// ### Add headers one at a time <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_add_header.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn json_api_request(token: String) -> client.ClientRequest {
///   client.new()
///   |> client.add_header("Authorization", "Bearer " <> token)
///   |> client.add_header("Content-Type", "application/json")
/// }
/// ```
pub fn add_header(
  client_request: ClientRequest,
  name: String,
  value: String,
) -> ClientRequest {
  ClientRequest(..client_request, headers: [
    Header(name, value),
    ..client_request.headers
  ])
}

// ============================================================================
// Request Inspection (Getters)
// ============================================================================

/// Get the HTTP method from a request
///
/// Returns the HTTP method (GET, POST, etc.) configured for the request.
///
/// ## Example
///
/// ### Read the method <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_method.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http.{Post}
///
/// pub fn request_method() -> http.Method {
///   let request = client.new() |> client.method(Post)
///   client.get_method(request)
/// }
/// ```
pub fn get_method(client_request: ClientRequest) -> http.Method {
  client_request.method
}

/// Get the URI scheme from a request
///
/// Returns the scheme (HTTP or HTTPS) configured for the request.
///
/// ## Example
///
/// ### Read the scheme <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_scheme.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http.{Http}
///
/// pub fn request_scheme() -> http.Scheme {
///   let request = client.new() |> client.scheme(Http)
///   client.get_scheme(request)
/// }
/// ```
pub fn get_scheme(client_request: ClientRequest) -> http.Scheme {
  client_request.scheme
}

/// Get the host from a request
///
/// Returns the hostname configured for the request.
///
/// ## Example
///
/// ### Read the host <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_host.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn request_host() -> String {
///   let request = client.new() |> client.host("api.example.com")
///   client.get_host(request)
/// }
/// ```
pub fn get_host(client_request: ClientRequest) -> String {
  client_request.host
}

/// Get the port from a request
///
/// Returns the optional port number configured for the request.
/// If None, the default port for the scheme will be used (80 for HTTP, 443 for HTTPS).
///
/// ## Example
///
/// ### Read the port <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_port.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn request_port() -> Option(Int) {
///   let request = client.new() |> client.port(8080)
///   client.get_port(request)
/// }
/// ```
pub fn get_port(client_request: ClientRequest) -> Option(Int) {
  client_request.port
}

/// Get the path from a request
///
/// Returns the request path configured for the request.
///
/// ## Example
///
/// ### Read the path <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_path.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn request_path() -> String {
///   let request = client.new() |> client.path("/api/users")
///   client.get_path(request)
/// }
/// ```
pub fn get_path(client_request: ClientRequest) -> String {
  client_request.path
}

/// Get the query string from a request
///
/// Returns the optional query string configured for the request.
///
/// ## Example
///
/// ### Read the query string <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_query.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn request_query() -> Option(String) {
///   let request = client.new() |> client.query("page=1&limit=10")
///   client.get_query(request)
/// }
/// ```
pub fn get_query(client_request: ClientRequest) -> Option(String) {
  client_request.query
}

/// Get the headers from a request
///
/// Returns the list of headers configured for the request.
///
/// ## Example
///
/// ### Read the headers <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_headers.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn request_headers() -> List(client.Header) {
///   let request =
///     client.new()
///     |> client.add_header("Authorization", "Bearer token")
///     |> client.add_header("Content-Type", "application/json")
///   client.get_headers(request)
/// }
/// ```
pub fn get_headers(client_request: ClientRequest) -> List(Header) {
  client_request.headers
}

/// Get the body from a request
///
/// Returns the request body as a string.
///
/// ## Example
///
/// ### Read the body <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_body.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn request_body() -> String {
///   let request = client.new() |> client.body("{\"name\": \"Alice\"}")
///   client.get_body(request)
/// }
/// ```
pub fn get_body(client_request: ClientRequest) -> String {
  client_request.body
}

/// Get the timeout from a request
///
/// Returns the optional timeout in milliseconds configured for the request.
/// If None, the default timeout (30000ms) will be used.
///
/// ## Example
///
/// ### Read the timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_timeout.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn request_timeout() -> Option(Int) {
///   let request = client.new() |> client.timeout(5000)
///   client.get_timeout(request)
/// }
/// ```
pub fn get_timeout(client_request: ClientRequest) -> Option(Int) {
  client_request.timeout
}

/// Get the configured TCP connection timeout
///
/// Returns `None` if the default (15000ms) will be used.
///
/// ## Example
///
/// ### Read the request settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn internal_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("internal.example.com")
///   |> client.certificate_authority_file("certs/internal-ca.pem")
///   |> client.connect_timeout(2000)
///   |> client.auto_redirect(False)
/// }
///
/// pub fn request_settings(
///   request: client.ClientRequest,
/// ) -> #(Option(String), Option(Int), Option(Bool)) {
///   #(
///     client.get_certificate_authority_file(request),
///     client.get_connect_timeout(request),
///     client.get_auto_redirect(request),
///   )
/// }
/// ```
pub fn get_connect_timeout(client_request: ClientRequest) -> Option(Int) {
  client_request.connect_timeout
}

/// Get the configured auto-redirect setting
///
/// Returns `None` if the default (True) will be used.
///
/// ## Example
///
/// ### Read the request settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn internal_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("internal.example.com")
///   |> client.certificate_authority_file("certs/internal-ca.pem")
///   |> client.connect_timeout(2000)
///   |> client.auto_redirect(False)
/// }
///
/// pub fn request_settings(
///   request: client.ClientRequest,
/// ) -> #(Option(String), Option(Int), Option(Bool)) {
///   #(
///     client.get_certificate_authority_file(request),
///     client.get_connect_timeout(request),
///     client.get_auto_redirect(request),
///   )
/// }
/// ```
pub fn get_auto_redirect(client_request: ClientRequest) -> Option(Bool) {
  client_request.auto_redirect
}

/// Get the configured protocol preference for the connection.
///
/// Returns `None` if no explicit protocol preference has been set,
/// meaning transport-specific defaults will apply.
///
/// ### Read the protocols <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_protocols.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{Http2Only}
/// import gleam/option.{type Option}
///
/// pub fn request_protocols() -> Option(client.Protocols) {
///   let request = client.new() |> client.protocols(Http2Only)
///   client.get_protocols(request)
/// }
/// ```
pub fn get_protocols(client_request: ClientRequest) -> Option(Protocols) {
  client_request.protocols
}

/// Get the certificate authority file for this request, if one is set
///
/// Returns `None` when the request uses the client-wide default.
///
/// ## Example
///
/// ### Read the request settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn internal_request() -> client.ClientRequest {
///   client.new()
///   |> client.host("internal.example.com")
///   |> client.certificate_authority_file("certs/internal-ca.pem")
///   |> client.connect_timeout(2000)
///   |> client.auto_redirect(False)
/// }
///
/// pub fn request_settings(
///   request: client.ClientRequest,
/// ) -> #(Option(String), Option(Int), Option(Bool)) {
///   #(
///     client.get_certificate_authority_file(request),
///     client.get_connect_timeout(request),
///     client.get_auto_redirect(request),
///   )
/// }
/// ```
pub fn get_certificate_authority_file(
  client_request: ClientRequest,
) -> Option(String) {
  client_request.certificate_authority_file
}

/// Get the recorder from a request
///
/// Returns the optional recorder attached to the request for recording or playback.
///
/// ## Example
///
/// ### Check for a recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_recorder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/option
/// import gleam/result
///
/// pub fn has_recorder(mocks_directory: String) -> Result(Bool, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///   let request = client.new() |> client.recorder(rec)
///   option.is_some(client.get_recorder(request))
/// }
/// ```
pub fn get_recorder(
  client_request: ClientRequest,
) -> Option(recorder.Recorder) {
  client_request.recorder
}

// ============================================================================
// Message-Based Streaming Types
// ============================================================================

/// Opaque request identifier for internal streaming
///
/// A unique identifier for an active HTTP stream. You will usually only see
/// a `RequestId` inside `StreamMessage` values processed by the stream process
/// created by `start_stream()`, or when using the low-level `cancel_stream()`.
///
/// ## Usage
///
/// Most users never need to construct or store `RequestId`. Prefer controlling
/// streams via `StreamHandle` (`cancel_stream_handle`, `is_stream_active`,
/// `await_stream`).
///
/// ## Notes
///
/// - RequestId values are opaque - do not rely on their internal structure
/// - RequestIds are unique per VM instance but not stable across restarts
/// - Use pattern matching or equality comparison to identify streams
pub opaque type RequestId {
  RequestId(id: String)
}

/// Stream message types emitted by internal streaming machinery
///
/// `start_stream()` runs a stream loop in a dedicated process; that process
/// receives and decodes gun messages into these variants.
///
/// ## Message Flow
///
/// 1. `StreamStart` - Headers received, body chunks coming
/// 2. `Chunk` - Zero or more data chunks
/// 3. `StreamEnd` or `StreamError` - Stream completed normally
/// 4. `DecodeError` - FFI layer corruption (rare, should be reported as a bug)
///
/// ## DecodeError
///
/// `DecodeError` indicates the Erlang→Gleam FFI boundary received a malformed
/// message from `gun`. This is **not a normal HTTP error** - it means either:
///
/// - Erlang/OTP version incompatibility with this library
/// - Memory corruption or other serious runtime issue
/// - A bug in this library's FFI code
///
/// **What to do:** If you see a `DecodeError`, please report it as a bug at
/// https://github.com/TrustBound/dream_http_client/issues with the full error message.
/// The error message includes debug information to help diagnose the issue.
///
/// Unlike `StreamError` which has a `RequestId`, `DecodeError` does not because
/// the request ID itself could not be decoded from the corrupted message.
pub type StreamMessage {
  /// Stream started, headers received
  StreamStart(request_id: RequestId, headers: List(Header))
  /// Data chunk received
  Chunk(request_id: RequestId, data: BitArray)
  /// Stream completed successfully
  StreamEnd(request_id: RequestId, headers: List(Header))
  /// Stream failed with error (connection drop, timeout, HTTP error, etc.)
  StreamError(request_id: RequestId, error: StreamFailure)
  /// Failed to decode stream message from Erlang FFI (indicates library bug)
  DecodeError(reason: String)
}

/// Handle to a running HTTP stream
///
/// Opaque handle returned from `start_stream()` representing a stream running in
/// a dedicated BEAM process. Use this handle to control the stream lifecycle.
///
/// ## Lifecycle Management
///
/// - `await_stream(handle)` - Wait for stream to complete
/// - `cancel_stream_handle(handle)` - Stop the stream early
/// - `is_stream_active(handle)` - Check if still running
///
/// ## Process Isolation
///
/// Each stream runs in its own BEAM process, which means:
/// - Multiple streams run concurrently without blocking
/// - Stream crashes don't affect your application
/// - Your process mailbox stays clean (HTTP messages go to stream process)
/// - Callbacks execute in the stream process, not your process
///
/// ## Example
///
/// ### Wait for a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_stream_handle.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn run_to_end() -> Result(Bool, String) {
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/fast")
///   use stream <- result.map(client.start_stream(request))
///   // Wait for completion
///   client.await_stream(stream)
///   // False: the stream is done
///   client.is_stream_active(stream)
/// }
/// ```
pub opaque type StreamHandle {
  StreamHandle(pid: process.Pid)
}

// ============================================================================
// Request Execution
// ============================================================================

/// Make a blocking HTTP request and get the complete response
///
/// Sends an HTTP request and collects all response chunks, returning the
/// complete response with status code, headers, and body. This is ideal for:
///
/// - JSON API responses
/// - Small files or documents
/// - Any case where you need the full response before processing
///
/// For large responses or when you need non-blocking streaming, use
/// `stream_yielder()` or `start_stream()` instead.
///
/// ## Recording and Playback
///
/// When a recorder is attached (via `recorder()`), this function fully supports
/// both recording and playback. In record mode, the real response is persisted
/// to disk. In playback mode, the recorded response is returned without making
/// a network call.
///
/// ## Parameters
///
/// - `client_request`: The configured HTTP request
///
/// ## Returns
///
/// - `Ok(HttpResponse)`: Successful response (status < 400) with status, headers, and body
/// - `Error(ResponseError(response))`: HTTP error response (status >= 400) with full response
/// - `Error(RequestError(error: transport_error))`: Connection failure, timeout, or other transport error
///
/// ## Example
///
/// ### Send and handle errors <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_send.gleam#L5-L25"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   HttpResponse, RequestError, ResponseError, host, path, port, scheme, send,
///   transport_error_to_string,
/// }
/// import gleam/http
///
/// pub fn fetch_text() -> Result(String, String) {
///   let result =
///     client.new()
///     |> scheme(http.Http)
///     |> host("localhost")
///     |> port(9876)
///     |> path("/text")
///     |> send()
///
///   case result {
///     Ok(HttpResponse(body: body, ..)) -> Ok(body)
///     Error(ResponseError(response: response)) -> Error(response.body)
///     Error(RequestError(error: error)) -> Error(transport_error_to_string(error))
///   }
/// }
/// ```
pub fn send(client_request: ClientRequest) -> Result(HttpResponse, SendError) {
  case client_request.recorder {
    option.Some(recorder_instance) ->
      send_with_recorder(client_request, recorder_instance)
    option.None -> send_without_recorder(client_request)
  }
}

fn send_without_recorder(
  client_request: ClientRequest,
) -> Result(HttpResponse, SendError) {
  send_client_request_via_gun(client_request)
}

fn send_with_recorder(
  client_request: ClientRequest,
  recorder_instance: recorder.Recorder,
) -> Result(HttpResponse, SendError) {
  let recorded_request = client_request_to_recorded_request(client_request)

  case recorder.find_recording(recorder_instance, recorded_request) {
    Ok(option.Some(recording.Recording(_, response))) ->
      handle_recorded_blocking_response(response)
    Ok(option.None) ->
      send_and_maybe_record(client_request, recorder_instance, recorded_request)
    Error(reason) -> Error(RequestError(error: Unexpected(raw: reason)))
  }
}

fn handle_recorded_blocking_response(
  response: recording.RecordedResponse,
) -> Result(HttpResponse, SendError) {
  case response {
    recording.BlockingResponse(status, headers, body) ->
      response_result(status, headers, body)
    recording.StreamingResponse(_, _, _) ->
      Error(
        RequestError(error: Unexpected(
          raw: "Recording contains streaming response, use stream_yielder() instead",
        )),
      )
  }
}

fn send_and_maybe_record(
  client_request: ClientRequest,
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
) -> Result(HttpResponse, SendError) {
  case send_client_request_via_gun_with_meta(client_request) {
    Ok(#(status, headers, body)) -> {
      let recorded_response =
        recording.BlockingResponse(status: status, headers: headers, body: body)
      let response_for_recording = case
        recorder.is_record_mode(recorder_instance)
      {
        True ->
          recorder.transform_response(
            recorder_instance,
            recorded_request,
            recorded_response,
          )
        False -> recorded_response
      }

      record_response_if_needed(
        recorder_instance,
        recorded_request,
        response_for_recording,
      )

      response_result(status, headers, body)
    }
    Error(error) -> Error(RequestError(error: error))
  }
}

fn record_response_if_needed(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> Nil {
  case recorder.is_record_mode(recorder_instance) {
    True -> {
      let recorder_entry =
        recording.Recording(request: recorded_request, response: response)
      recorder.add_recording(recorder_instance, recorder_entry)
    }
    False -> Nil
  }
}

fn send_client_request_via_gun(
  client_request: ClientRequest,
) -> Result(HttpResponse, SendError) {
  case send_client_request_via_gun_with_meta(client_request) {
    Ok(#(status, headers, body)) -> response_result(status, headers, body)
    Error(error) -> Error(RequestError(error: error))
  }
}

fn send_client_request_via_gun_with_meta(
  client_request: ClientRequest,
) -> Result(#(Int, List(#(String, String)), String), TransportError) {
  let http_request = to_http_request(client_request)
  let url = build_url(http_request)
  let method_atom = internal.atomize_method(http_request.method)
  let method_dynamic = atom.to_dynamic(method_atom)
  let body = <<http_request.body:utf8>>
  let timeout_value = resolve_timeout(client_request)
  let connect_timeout_value = resolve_connect_timeout(client_request)
  let auto_redirect_value = resolve_auto_redirect(client_request)
  let connection_settings = resolve_connection_settings(client_request)

  send_sync(
    method_dynamic,
    url,
    http_request.headers,
    body,
    timeout_value,
    connect_timeout_value,
    auto_redirect_value,
    connection_settings,
  )
  // Response bodies are opaque bytes, not text: S3 objects, PDFs, images. On
  // the BEAM a String IS a binary, so reinterpret the bytes without UTF-8
  // validation — rejecting non-UTF8 here made every binary download fail
  // with a transport error.
  |> result.map(fn(response) {
    let #(status, headers, response_body) = response
    #(status, headers, unchecked_bits_to_string(response_body))
  })
}

@external(erlang, "gleam_stdlib", "identity")
fn unchecked_bits_to_string(bits: BitArray) -> String

fn client_request_to_recorded_request(
  client_request: ClientRequest,
) -> recording.RecordedRequest {
  recording.RecordedRequest(
    method: client_request.method,
    scheme: client_request.scheme,
    host: client_request.host,
    port: client_request.port,
    path: client_request.path,
    query: client_request.query,
    headers: headers_to_tuples(client_request.headers),
    body: client_request.body,
  )
}

fn resolve_timeout(client_request: ClientRequest) -> Int {
  case client_request.timeout {
    Some(timeout_value) -> timeout_value
    None -> 30_000
  }
}

fn resolve_connect_timeout(client_request: ClientRequest) -> Int {
  case client_request.connect_timeout {
    Some(ms) -> ms
    None -> 15_000
  }
}

fn resolve_auto_redirect(client_request: ClientRequest) -> Bool {
  case client_request.auto_redirect {
    Some(enabled) -> enabled
    None -> True
  }
}

fn resolve_connection_settings(
  request: ClientRequest,
) -> internal.ConnectionSettings {
  let protocols = case request.protocols {
    option.Some(Http1Only) -> atom.create("http1_only")
    option.Some(Http2Only) -> atom.create("http2_only")
    option.Some(Http2Preferred) -> atom.create("http2_preferred")
    option.None -> atom.create("default")
  }
  internal.ConnectionSettings(
    protocols: protocols,
    certificate_authority_file: request.certificate_authority_file,
  )
}

@external(erlang, "dream_http_shim", "request_sync")
fn send_sync(
  method: d.Dynamic,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
  connect_timeout_ms: Int,
  autoredirect: Bool,
  connection_settings: internal.ConnectionSettings,
) -> Result(#(Int, List(#(String, String)), BitArray), TransportError)

/// Stream HTTP response chunks using a yielder
///
/// Sends an HTTP request and returns a yielder that produces chunks of the
/// response body as they arrive from the server. This allows you to process
/// large responses incrementally without loading the entire response into memory.
///
/// **Use this for simple sequential streaming:**
/// - AI/LLM inference endpoints (stream tokens)
/// - Simple file downloads
/// - Scripts or one-off operations
///
/// **For OTP actors with concurrency, use `start_stream()` instead.**
///
/// ## Recording and Playback
///
/// When a recorder is attached (via `recorder()`), this function fully supports
/// both recording and playback:
///
/// - **Record mode**: Streams from the real server and records chunks to disk,
///   capturing timing information between chunks for realistic replay.
/// - **Playback mode**: Yields recorded chunks from the fixture file. No network
///   calls are made.
///
/// The same `StreamingResponse` fixture format is shared with `start_stream()`,
/// so recordings made with either function can be played back by both.
///
/// ## Error Semantics
///
/// The yielder produces `Result(BytesTree, StreamFailure)` for each chunk:
/// - `Ok(chunk)` - Successful chunk, more may follow
/// - `Error(failure)` - **Terminal error**, stream is done
///
/// After an `Error`, the yielder immediately returns `Done` on the next call.
/// This design reflects that HTTP stream errors (timeouts, connection drops,
/// etc.) are **not recoverable** - you cannot continue reading from a broken stream.
///
/// **Normal stream completion**: When the stream finishes successfully, the yielder
/// returns `Done` (no more items). The stream does NOT yield an error for normal completion.
///
/// Errors are structured as `StreamFailure`:
/// - `HttpFailure(response)` - Server returned non-2xx (status, headers, body available)
/// - `TransportFailure(error)` - Transport-level failure (timeout, connection drop, etc.)
///
/// ## Parameters
///
/// - `client_request`: The configured HTTP request
///
/// ## Returns
///
/// A `Yielder` that produces `Result(BytesTree, StreamFailure)`. Always check each
/// result - errors are terminal and mean the stream has ended.
///
/// ## Examples
///
/// **Streaming and processing chunks as they arrive:**
///
/// ### Count the bytes of a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_yielder_basic.gleam#L5-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type StreamFailure, host, path, port, scheme, stream_yielder,
/// }
/// import gleam/bytes_tree.{type BytesTree}
/// import gleam/http
/// import gleam/result
/// import gleam/yielder
///
/// pub fn count_stream_bytes() -> Result(Int, StreamFailure) {
///   client.new()
///   |> scheme(http.Http)
///   |> host("localhost")
///   |> port(9876)
///   |> path("/stream/fast")
///   |> stream_yielder()
///   |> yielder.try_fold(0, add_chunk_size)
/// }
///
/// fn add_chunk_size(
///   total: Int,
///   chunk_result: Result(BytesTree, StreamFailure),
/// ) -> Result(Int, StreamFailure) {
///   use chunk <- result.map(chunk_result)
///   total + bytes_tree.byte_size(chunk)
/// }
/// ```
///
/// **Collecting all chunks into a list:**
///
/// ### Collect a stream into a string <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_stream_to_string.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{host, path, port, scheme, stream_yielder}
/// import gleam/bit_array
/// import gleam/bytes_tree
/// import gleam/http
/// import gleam/list
/// import gleam/result
/// import gleam/string
/// import gleam/yielder
///
/// pub fn stream_to_string() -> Result(String, String) {
///   // The stream ends by itself: no need for take()
///   let chunks =
///     client.new()
///     |> scheme(http.Http)
///     |> host("localhost")
///     |> port(9876)
///     |> path("/stream/fast")
///     |> stream_yielder()
///     |> yielder.to_list()
///
///   case list.try_map(chunks, fn(chunk) { chunk }) {
///     Ok(chunk_list) ->
///       chunk_list
///       |> list.map(bytes_tree.to_bit_array)
///       |> list.map(fn(data) { bit_array.to_string(data) |> result.unwrap("") })
///       |> string.join("")
///       |> Ok
///     Error(failure) -> Error(client.stream_failure_to_string(failure))
///   }
/// }
/// ```
pub fn stream_yielder(
  client_request: ClientRequest,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  case client_request.recorder {
    option.Some(recorder_instance) ->
      stream_yielder_with_recorder(client_request, recorder_instance)
    option.None -> create_stream_yielder_from_client_request(client_request)
  }
}

fn stream_yielder_with_recorder(
  client_request: ClientRequest,
  recorder_instance: recorder.Recorder,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  let recorded_request = client_request_to_recorded_request(client_request)

  case recorder.find_recording(recorder_instance, recorded_request) {
    Ok(option.Some(recording.Recording(_, response))) ->
      create_yielder_from_recorded_response(response)
    Ok(option.None) -> create_stream_yielder_from_client_request(client_request)
    Error(reason) ->
      yielder.single(Error(TransportFailure(error: Unexpected(raw: reason))))
  }
}

fn create_yielder_from_recorded_response(
  response: recording.RecordedResponse,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  case response {
    recording.StreamingResponse(_, _, chunks) ->
      create_yielder_from_chunks(chunks)
    recording.BlockingResponse(_, _, body) -> {
      // Blocking response - return as single chunk
      let chunk = bytes_tree.from_bit_array(<<body:utf8>>)
      yielder.single(Ok(chunk))
    }
  }
}

fn create_stream_yielder_from_client_request(
  client_request: ClientRequest,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  let http_request = to_http_request(client_request)
  let timeout_value = resolve_timeout(client_request)
  let connect_timeout_value = resolve_connect_timeout(client_request)
  let auto_redirect_value = resolve_auto_redirect(client_request)
  let connection_settings = resolve_connection_settings(client_request)

  case client_request.recorder {
    option.Some(recorder_instance) ->
      stream_yielder_with_record_mode(
        client_request,
        recorder_instance,
        http_request,
        timeout_value,
        connect_timeout_value,
        auto_redirect_value,
        connection_settings,
      )
    option.None ->
      create_plain_yielder(
        http_request,
        timeout_value,
        connect_timeout_value,
        auto_redirect_value,
        connection_settings,
      )
  }
}

fn stream_yielder_with_record_mode(
  client_request: ClientRequest,
  recorder_instance: recorder.Recorder,
  http_request: request.Request(String),
  timeout_value: Int,
  connect_timeout_value: Int,
  auto_redirect_value: Bool,
  connection_settings: internal.ConnectionSettings,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  case recorder.is_record_mode(recorder_instance) {
    True -> {
      let recorded_request = client_request_to_recorded_request(client_request)
      let initial_state =
        RecordingYielderState(
          owner: None,
          http_req: http_request,
          timeout_ms: timeout_value,
          connect_timeout_ms: connect_timeout_value,
          auto_redirect: auto_redirect_value,
          connection_settings: connection_settings,
          recorder: recorder_instance,
          recorded_request: recorded_request,
          start_headers: [],
          chunks: [],
          last_chunk_time: 0,
        )
      yielder.unfold(initial_state, handle_recording_yielder_unfold)
    }
    False ->
      create_plain_yielder(
        http_request,
        timeout_value,
        connect_timeout_value,
        auto_redirect_value,
        connection_settings,
      )
  }
}

fn create_plain_yielder(
  http_request: request.Request(String),
  timeout_value: Int,
  connect_timeout_value: Int,
  auto_redirect_value: Bool,
  connection_settings: internal.ConnectionSettings,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  let initial_state =
    YielderState(
      owner: None,
      http_req: http_request,
      timeout_ms: timeout_value,
      connect_timeout_ms: connect_timeout_value,
      auto_redirect: auto_redirect_value,
      connection_settings: connection_settings,
    )
  yielder.unfold(initial_state, handle_yielder_unfold_with_deps)
}

fn create_yielder_from_chunks(
  chunks: List(recording.Chunk),
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  chunks
  |> yielder.from_list
  |> yielder.map(convert_chunk_to_result)
}

fn convert_chunk_to_result(
  chunk: recording.Chunk,
) -> Result(bytes_tree.BytesTree, StreamFailure) {
  // TODO: Add delay based on chunk.delay_ms
  let data = bytes_tree.from_bit_array(chunk.data)
  Ok(data)
}

type YielderState {
  YielderState(
    owner: Option(process.Pid),
    http_req: request.Request(String),
    timeout_ms: Int,
    connect_timeout_ms: Int,
    auto_redirect: Bool,
    connection_settings: internal.ConnectionSettings,
  )
}

type RecordingYielderState {
  RecordingYielderState(
    owner: Option(process.Pid),
    http_req: request.Request(String),
    timeout_ms: Int,
    connect_timeout_ms: Int,
    auto_redirect: Bool,
    connection_settings: internal.ConnectionSettings,
    recorder: recorder.Recorder,
    recorded_request: recording.RecordedRequest,
    start_headers: List(#(String, String)),
    chunks: List(recording.Chunk),
    last_chunk_time: Int,
  )
}

fn handle_yielder_unfold_with_deps(
  state: YielderState,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case state.owner {
    None -> handle_yielder_start_with_state(state)
    Some(owner) -> handle_yielder_next_with_state(owner, state)
  }
}

fn to_http_request(client_request: ClientRequest) -> request.Request(String) {
  request.Request(
    method: client_request.method,
    headers: headers_to_tuples(client_request.headers),
    body: client_request.body,
    scheme: client_request.scheme,
    host: client_request.host,
    port: client_request.port,
    path: client_request.path,
    query: client_request.query,
  )
}

fn headers_to_tuples(headers: List(Header)) -> List(#(String, String)) {
  list.map(headers, fn(h) { #(h.name, h.value) })
}

fn tuples_to_headers(tuples: List(#(String, String))) -> List(Header) {
  list.map(tuples, fn(t) { Header(name: t.0, value: t.1) })
}

fn response_result(
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> Result(HttpResponse, SendError) {
  let response =
    HttpResponse(
      status: status,
      headers: tuples_to_headers(headers),
      body: body,
    )
  case status >= 400 {
    True -> Error(ResponseError(response: response))
    False -> Ok(response)
  }
}

fn handle_yielder_start_with_state(
  state: YielderState,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  let owner =
    internal.start_gun_stream(
      state.http_req,
      state.timeout_ms,
      state.connect_timeout_ms,
      state.auto_redirect,
      state.connection_settings,
    )
  case internal.fetch_next(owner) {
    internal.Chunk(bin) ->
      yielder.Next(
        Ok(bytes_tree.from_bit_array(bin)),
        YielderState(..state, owner: Some(owner)),
      )
    internal.Done(_) -> yielder.Done
    internal.Failed(failure) -> yielder.Next(Error(failure), state)
  }
}

fn handle_yielder_next_with_state(
  owner: process.Pid,
  state: YielderState,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case internal.fetch_next(owner) {
    internal.Chunk(bin) ->
      yielder.Next(Ok(bytes_tree.from_bit_array(bin)), state)
    internal.Done(_) -> yielder.Done
    internal.Failed(failure) -> yielder.Next(Error(failure), state)
  }
}

// Get current time in milliseconds for recording delays
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time_native() -> Int

fn get_time_ms() -> Int {
  // Convert native time units to milliseconds
  let native = monotonic_time_native()
  // erlang:convert_time_unit(native, native, millisecond)
  convert_time_unit(native, atom.create("native"), atom.create("millisecond"))
}

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(time: Int, from_unit: atom.Atom, to_unit: atom.Atom) -> Int

fn handle_recording_yielder_unfold(
  state: RecordingYielderState,
) -> yielder.Step(
  Result(bytes_tree.BytesTree, StreamFailure),
  RecordingYielderState,
) {
  case state.owner {
    None -> handle_recording_yielder_start(state)
    Some(owner) -> handle_recording_yielder_next(owner, state)
  }
}

fn handle_recording_yielder_start(
  state: RecordingYielderState,
) -> yielder.Step(
  Result(bytes_tree.BytesTree, StreamFailure),
  RecordingYielderState,
) {
  let owner =
    internal.start_gun_stream(
      state.http_req,
      state.timeout_ms,
      state.connect_timeout_ms,
      state.auto_redirect,
      state.connection_settings,
    )
  let start_headers = case internal.fetch_start_headers(owner) {
    Ok(headers) -> headers
    Error(failure) -> {
      io.println_error(
        "Failed to fetch stream_start headers for recording: "
        <> stream_failure_to_string(failure),
      )
      []
    }
  }
  let now = get_time_ms()

  case internal.fetch_next(owner) {
    internal.Chunk(bin) -> {
      // First chunk - record it
      let chunk = recording.Chunk(data: bin, delay_ms: 0)
      let new_state =
        RecordingYielderState(
          ..state,
          owner: Some(owner),
          start_headers: start_headers,
          chunks: [chunk],
          last_chunk_time: now,
        )
      yielder.Next(Ok(bytes_tree.from_bit_array(bin)), new_state)
    }
    internal.Done(_) -> {
      // Empty stream - save recording with no chunks
      save_streaming_recording(
        RecordingYielderState(..state, start_headers: start_headers),
        [],
      )
      yielder.Done
    }
    internal.Failed(failure) -> yielder.Next(Error(failure), state)
  }
}

fn handle_recording_yielder_next(
  owner: process.Pid,
  state: RecordingYielderState,
) -> yielder.Step(
  Result(bytes_tree.BytesTree, StreamFailure),
  RecordingYielderState,
) {
  let now = get_time_ms()

  case internal.fetch_next(owner) {
    internal.Chunk(bin) -> {
      let chunk =
        recording.Chunk(data: bin, delay_ms: now - state.last_chunk_time)
      let new_state =
        RecordingYielderState(
          ..state,
          chunks: [chunk, ..state.chunks],
          last_chunk_time: now,
        )
      yielder.Next(Ok(bytes_tree.from_bit_array(bin)), new_state)
    }
    internal.Done(_) -> {
      save_streaming_recording(state, state.chunks)
      yielder.Done
    }
    internal.Failed(failure) -> {
      save_streaming_recording(state, state.chunks)
      yielder.Next(Error(failure), state)
    }
  }
}

fn save_streaming_recording(
  state: RecordingYielderState,
  chunks: List(recording.Chunk),
) -> Nil {
  // Reverse chunks to get correct order (we prepended them)
  let ordered_chunks = list.reverse(chunks)

  // gun only streams body chunks for successful responses (200/206). We
  // infer 206 if Content-Range is present; otherwise default to 200.
  let status = case
    list.any(state.start_headers, fn(h) {
      string.lowercase(h.0) == "content-range"
    })
  {
    True -> 206
    False -> 200
  }

  let response =
    recording.StreamingResponse(
      status: status,
      headers: state.start_headers,
      chunks: ordered_chunks,
    )

  let rec =
    recording.Recording(request: state.recorded_request, response: response)

  recorder.add_recording(state.recorder, rec)
}

// Internal: Start a message-based streaming HTTP request
// Used by start_stream() to start the low-level HTTP stream via gun, after
// it found no recording to play back.
fn start_stream_messages(client_request: ClientRequest) -> RequestId {
  let http_request = to_http_request(client_request)
  internal.start_stream_messages(
    internal.atomize_method(http_request.method),
    build_url(http_request),
    http_request.headers,
    <<http_request.body:utf8>>,
    resolve_timeout(client_request),
    resolve_connect_timeout(client_request),
    resolve_auto_redirect(client_request),
    resolve_connection_settings(client_request),
  )
  |> RequestId
}

fn record_message_stream_if_needed(
  request_id: RequestId,
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
) -> Nil {
  case recorder.is_record_mode(recorder_instance) {
    True ->
      store_message_stream_recorder(
        request_id,
        recorder_instance,
        recorded_request,
      )
    False -> Nil
  }
}

fn build_url(request: request.Request(String)) -> String {
  let port_string = case request.port {
    option.Some(port) -> ":" <> int.to_string(port)
    option.None -> ""
  }
  let query_string = case request.query {
    option.Some(query) -> "?" <> query
    option.None -> ""
  }
  http.scheme_to_string(request.scheme)
  <> "://"
  <> request.host
  <> port_string
  <> request.path
  <> query_string
}

// Internal: Add stream message handling to a selector
// Used by start_stream() to receive HTTP messages in spawned process
fn select_stream_messages(
  selector: process.Selector(msg),
  mapper: fn(StreamMessage) -> msg,
) -> process.Selector(msg) {
  selector
  |> process.select_record(
    tag: atom.create("http"),
    fields: 1,
    mapping: create_selector_mapper(mapper),
  )
}

fn create_selector_mapper(
  mapper: fn(StreamMessage) -> msg,
) -> fn(d.Dynamic) -> msg {
  // process.select_record requires a callback of type fn(Dynamic) -> msg.
  // This small helper exists to adapt that interface while keeping the
  // higher-level mapper explicit and testable.
  apply_mapper_to_dynamic(_, mapper)
}

fn apply_mapper_to_dynamic(
  dyn: d.Dynamic,
  mapper: fn(StreamMessage) -> msg,
) -> msg {
  // The Erlang shim builds the StreamMessage value itself.
  let stream_msg = stream_message_from_selector(dyn)

  // Record the message if this stream has a recorder
  record_stream_message(stream_msg)

  mapper(stream_msg)
}

@external(erlang, "dream_http_shim", "decode_stream_message_for_selector")
fn stream_message_from_selector(message: d.Dynamic) -> StreamMessage

/// Start an HTTP stream with callback handlers
///
/// Spawns a dedicated process to handle HTTP streaming and calls your callbacks
/// as messages arrive. This is the recommended API for streaming in OTP
/// applications and concurrent contexts.
///
/// Returns a `StreamHandle` immediately (non-blocking). The stream runs in a
/// separate process, and your callbacks execute in that process.
///
/// ## Recording and Playback
///
/// When a recorder is attached (via `recorder()`), this function fully supports
/// both recording and playback:
///
/// - **Record mode**: Streams from the real server and records chunks to disk.
///   The recorded fixture captures each chunk along with timing information.
/// - **Playback mode**: Replays recorded chunks directly via your callbacks —
///   `on_stream_start`, `on_stream_chunk`, and `on_stream_end` are called in
///   sequence with the recorded data. No network calls are made.
///
/// The same `StreamingResponse` fixture format is shared with `stream_yielder()`,
/// so recordings made with either function can be played back by both.
///
/// ## Parameters
///
/// - `request`: The configured HTTP request with callbacks set via builder pattern
///
/// ## Returns
///
/// - `Ok(StreamHandle)`: Stream started successfully
/// - `Error(String)`: Failed to start stream
///
/// ## Example
///
/// ### Stream with callbacks <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_messages_basic.gleam#L5-L54"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type Header, type StreamFailure, await_stream, host, on_stream_chunk,
///   on_stream_end, on_stream_error, on_stream_start, path, port, scheme,
///   start_stream, stream_failure_to_string,
/// }
/// import gleam/bit_array
/// import gleam/http
/// import gleam/io
///
/// pub fn stream_and_print() -> Result(Nil, String) {
///   let stream_result =
///     client.new()
///     |> scheme(http.Http)
///     |> host("localhost")
///     |> port(9876)
///     |> path("/stream/fast")
///     |> on_stream_start(print_stream_start)
///     |> on_stream_chunk(print_chunk)
///     |> on_stream_end(print_stream_end)
///     |> on_stream_error(print_stream_error)
///     |> start_stream()
///
///   case stream_result {
///     Error(reason) -> Error(reason)
///     Ok(stream_handle) -> {
///       // Wait for the stream to complete
///       await_stream(stream_handle)
///       Ok(Nil)
///     }
///   }
/// }
///
/// fn print_stream_start(_headers: List(Header)) -> Nil {
///   io.println("Stream started")
/// }
///
/// fn print_chunk(data: BitArray) -> Nil {
///   case bit_array.to_string(data) {
///     Ok(text) -> io.print(text)
///     Error(Nil) -> io.print("<binary>")
///   }
/// }
///
/// fn print_stream_end(_headers: List(Header)) -> Nil {
///   io.println("\nStream completed")
/// }
///
/// fn print_stream_error(failure: StreamFailure) -> Nil {
///   io.println_error("Stream error: " <> stream_failure_to_string(failure))
/// }
/// ```
pub fn start_stream(request: ClientRequest) -> Result(StreamHandle, String) {
  let stream_pid = process.spawn_unlinked(fn() { run_stream_process(request) })

  Ok(StreamHandle(pid: stream_pid))
}

fn run_stream_process(request: ClientRequest) -> Nil {
  case request.recorder {
    None -> stream_live(request)
    Some(rec) -> {
      let recorded_request = client_request_to_recorded_request(request)
      case recorder.find_recording(rec, recorded_request) {
        Ok(Some(recording.Recording(_, response))) ->
          replay_recorded_stream(request, response)
        Ok(None) -> {
          let selector = stream_message_selector()
          let request_id = start_stream_messages(request)
          record_message_stream_if_needed(request_id, rec, recorded_request)
          process_stream_loop(selector, request)
        }
        Error(reason) ->
          report_stream_error(
            request,
            TransportFailure(error: Unexpected(raw: reason)),
          )
      }
    }
  }
}

fn stream_live(request: ClientRequest) -> Nil {
  let selector = stream_message_selector()
  start_stream_messages(request)
  process_stream_loop(selector, request)
}

fn stream_message_selector() -> process.Selector(StreamMessage) {
  process.new_selector()
  |> select_stream_messages(fn(msg) { msg })
}

fn report_stream_error(request: ClientRequest, failure: StreamFailure) -> Nil {
  case request.on_stream_error {
    Some(on_error) -> on_error(failure)
    None -> Nil
  }
}

/// Replay a recorded response by directly invoking the stream callbacks.
/// Handles both StreamingResponse (multiple chunks) and BlockingResponse
/// (body delivered as a single chunk).
fn replay_recorded_stream(
  request: ClientRequest,
  response: recording.RecordedResponse,
) -> Nil {
  case response {
    recording.StreamingResponse(_, headers, chunks) -> {
      case request.on_stream_start {
        Some(cb) -> cb(list.map(headers, fn(h) { Header(h.0, h.1) }))
        None -> Nil
      }
      list.each(chunks, fn(chunk) {
        case request.on_stream_chunk {
          Some(cb) -> cb(chunk.data)
          None -> Nil
        }
      })
      case request.on_stream_end {
        Some(cb) -> cb([])
        None -> Nil
      }
    }
    recording.BlockingResponse(_, headers, body) -> {
      case request.on_stream_start {
        Some(cb) -> cb(list.map(headers, fn(h) { Header(h.0, h.1) }))
        None -> Nil
      }
      case request.on_stream_chunk {
        Some(cb) -> cb(<<body:utf8>>)
        None -> Nil
      }
      case request.on_stream_end {
        Some(cb) -> cb([])
        None -> Nil
      }
    }
  }
}

// The stream process has one stream, and the Erlang shim always ends it
// with a StreamEnd or a StreamError message: after the timeout of the
// request, the stream ends with a TimedOut failure.
fn process_stream_loop(
  selector: process.Selector(StreamMessage),
  request: ClientRequest,
) -> Nil {
  case process.selector_receive_forever(selector) {
    StreamStart(_, headers) -> {
      case request.on_stream_start {
        Some(on_start) -> on_start(headers)
        None -> Nil
      }
      process_stream_loop(selector, request)
    }
    Chunk(_, data) -> {
      case request.on_stream_chunk {
        Some(on_chunk) -> on_chunk(data)
        None -> Nil
      }
      process_stream_loop(selector, request)
    }
    StreamEnd(_, headers) -> {
      case request.on_stream_end {
        Some(on_end) -> on_end(headers)
        None -> Nil
      }
    }
    StreamError(_, failure) -> report_stream_error(request, failure)
    DecodeError(reason) ->
      report_stream_error(
        request,
        TransportFailure(error: Unexpected(raw: "DecodeError: " <> reason)),
      )
  }
}

/// Cancel a stream started with start_stream()
///
/// Stops the stream process and cancels the underlying HTTP request.
/// Safe to call multiple times on the same handle.
///
/// ## Example
///
/// ### Cancel a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_cancel_stream_handle.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn start_then_cancel() -> Result(Nil, String) {
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/slow")
///   use stream <- result.map(client.start_stream(request))
///   // Later:
///   client.cancel_stream_handle(stream)
/// }
/// ```
pub fn cancel_stream_handle(handle: StreamHandle) -> Nil {
  let StreamHandle(pid) = handle
  process.kill(pid)
}

/// Check if a stream is still active
///
/// Returns True if the stream process is still running, False otherwise.
///
/// ## Example
///
/// ### Check a running stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_is_stream_active.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn running_after_start() -> Result(Bool, String) {
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/slow")
///   use stream <- result.map(client.start_stream(request))
///   let active = client.is_stream_active(stream)
///   client.cancel_stream_handle(stream)
///   active
/// }
/// ```
pub fn is_stream_active(handle: StreamHandle) -> Bool {
  let StreamHandle(pid) = handle
  process.is_alive(pid)
}

/// Wait for a stream to complete
///
/// Blocks until the stream process exits. Use this when you need to wait
/// for the stream to finish before continuing.
///
/// Returns Ok(Nil) when stream completes.
///
/// For timeout behavior, use cancel_stream_handle() with a timer, or
/// implement your own timeout logic.
///
/// ## Example
///
/// ### Wait for a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_stream_handle.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
/// import gleam/result
///
/// pub fn run_to_end() -> Result(Bool, String) {
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/fast")
///   use stream <- result.map(client.start_stream(request))
///   // Wait for completion
///   client.await_stream(stream)
///   // False: the stream is done
///   client.is_stream_active(stream)
/// }
/// ```
pub fn await_stream(handle: StreamHandle) -> Nil {
  let StreamHandle(pid) = handle

  // Poll until process exits
  case process.is_alive(pid) {
    True -> {
      process.sleep(50)
      await_stream(handle)
    }
    False -> Nil
  }
}

/// Cancel an active streaming request (low-level API)
///
/// Cancels an HTTP stream given its `RequestId`.
///
/// **Note:** Most users should use `start_stream()` and `cancel_stream_handle()`
/// instead. `cancel_stream()` exists primarily to support internal stream
/// machinery and advanced integrations.
///
/// ## Parameters
///
/// - `request_id`: The request ID for an active internal stream
///
/// ## Example
///
/// This is typically not called directly unless you already have a `RequestId`.
pub fn cancel_stream(request_id: RequestId) -> Nil {
  let RequestId(id) = request_id
  internal.cancel_stream_by_string(id)
}

// ============================================================================
// Message-Based Streaming Recorder (Internal - ETS Storage)
// ============================================================================

type MessageStreamRecorderState {
  MessageStreamRecorderState(
    recorder: recorder.Recorder,
    recorded_request: recording.RecordedRequest,
    headers: List(#(String, String)),
    chunks: List(recording.Chunk),
    last_chunk_time: Option(Int),
  )
}

// ETS table name for recorder state
const recorder_table_name = "dream_http_client_stream_recorders"

@external(erlang, "dream_http_shim", "ets_insert")
fn ets_insert(
  table: String,
  key: String,
  recorder: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
  headers: List(#(String, String)),
  chunks: List(recording.Chunk),
  last_chunk_time: Option(Int),
) -> Nil

@external(erlang, "dream_http_shim", "ets_lookup")
fn ets_lookup(table: String, key: String) -> Option(MessageStreamRecorderState)

@external(erlang, "dream_http_shim", "ets_delete")
fn ets_delete(table: String, key: String) -> Bool

fn store_message_stream_recorder(
  request_id: RequestId,
  rec: recorder.Recorder,
  recorded_req: recording.RecordedRequest,
) -> Nil {
  let RequestId(id) = request_id
  ets_insert(recorder_table_name, id, rec, recorded_req, [], [], None)
}

fn get_message_stream_recorder(
  request_id: RequestId,
) -> Option(MessageStreamRecorderState) {
  let RequestId(id) = request_id
  ets_lookup(recorder_table_name, id)
}

fn update_message_stream_recorder(
  request_id: RequestId,
  state: MessageStreamRecorderState,
) -> Nil {
  let RequestId(id) = request_id
  ets_insert(
    recorder_table_name,
    id,
    state.recorder,
    state.recorded_request,
    state.headers,
    state.chunks,
    state.last_chunk_time,
  )
}

fn remove_message_stream_recorder(request_id: RequestId) -> Nil {
  let RequestId(id) = request_id
  ets_delete(recorder_table_name, id)
  Nil
}

fn record_stream_message(message: StreamMessage) -> Nil {
  case message {
    Chunk(request_id, data) -> {
      case get_message_stream_recorder(request_id) {
        option.Some(state) -> {
          let now = get_time_ms()
          let delay = case state.last_chunk_time {
            Some(last_time) -> now - last_time
            None -> 0
          }

          let chunk = recording.Chunk(data: data, delay_ms: delay)
          let new_state =
            MessageStreamRecorderState(
              recorder: state.recorder,
              recorded_request: state.recorded_request,
              headers: state.headers,
              chunks: [chunk, ..state.chunks],
              last_chunk_time: Some(now),
            )
          update_message_stream_recorder(request_id, new_state)
        }
        option.None -> Nil
      }
    }
    StreamEnd(request_id, headers) -> {
      case get_message_stream_recorder(request_id) {
        option.Some(state) -> {
          // Capture final (trailing) headers from stream_end when present.
          let header_tuples = headers_to_tuples(headers)
          let final_headers = case header_tuples == [] {
            True -> state.headers
            False -> header_tuples
          }
          let updated =
            MessageStreamRecorderState(..state, headers: final_headers)
          finish_message_stream_recording(request_id, updated)
        }
        option.None -> Nil
      }
    }
    StreamError(request_id, failure) -> {
      let RequestId(request_id_string) = request_id
      io.println_error(
        "HTTP stream error while recording messages for request "
        <> request_id_string
        <> ": "
        <> stream_failure_to_string(failure),
      )
      case get_message_stream_recorder(request_id) {
        option.Some(state) -> {
          finish_message_stream_recording(request_id, state)
        }
        option.None -> Nil
      }
    }
    StreamStart(request_id, headers) -> {
      case get_message_stream_recorder(request_id) {
        option.Some(state) -> {
          let header_tuples = headers_to_tuples(headers)
          let new_state =
            MessageStreamRecorderState(..state, headers: header_tuples)
          update_message_stream_recorder(request_id, new_state)
        }
        option.None -> Nil
      }
    }
    DecodeError(error_reason) -> {
      // DecodeError indicates a serious FFI problem at the FFI boundary.
      io.println_error(
        "Internal DecodeError in HTTP stream message recorder: " <> error_reason,
      )
      Nil
    }
  }
}

fn finish_message_stream_recording(
  request_id: RequestId,
  state: MessageStreamRecorderState,
) -> Nil {
  let ordered_chunks = list.reverse(state.chunks)

  let status = case
    list.any(state.headers, fn(h) { string.lowercase(h.0) == "content-range" })
  {
    True -> 206
    False -> 200
  }

  let response =
    recording.StreamingResponse(
      status: status,
      headers: state.headers,
      chunks: ordered_chunks,
    )

  let rec =
    recording.Recording(request: state.recorded_request, response: response)

  recorder.add_recording(state.recorder, rec)
  remove_message_stream_recorder(request_id)
}
