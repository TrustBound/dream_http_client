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
//// pub fn call_api(token: String) -> Result(BitArray, client.SendError) {
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
//// You can execute the same `ClientRequest` in four ways:
////
//// - **Blocking**: `send()` returns the full response body.
//// - **Pull streaming**: `stream_yielder()` returns a `yielder.Yielder` of chunks.
//// - **Callback streaming**: `start_stream()` spawns a stream process and calls
////   your callbacks (`on_stream_*`) as events arrive.
//// - **Message streaming**: `stream_to()` spawns a stream process that sends
////   typed `StreamMessage` values to a subject, for OTP actors.
////
//// The “right” choice is mostly about concurrency:
////
//// - Use `send()` for normal JSON APIs.
//// - Use `stream_yielder()` for scripts/one‑offs where blocking is fine.
//// - Use `start_stream()` when you need non‑blocking streaming in OTP code.
//// - Use `stream_to()` when an OTP actor must handle the stream as messages.
////
//// ## Recording and playback
////
//// Attach a recorder with `recorder()` to record real HTTP traffic to disk, or
//// to play back recordings without network calls. All four execution modes
//// (`send()`, `stream_yielder()`, `start_stream()`, `stream_to()`) fully
//// support both recording and playback. In playback mode, a request that no
//// recording matches fails with `NoRecording(method, url, directory,
//// nearest)` and is not sent. The error names the nearest recordings and
//// the parts that differ.
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
//// pub fn record_call(mocks_directory: String) -> Result(BitArray, String) {
////   use rec <- result.try(
////     recorder.new()
////     |> directory(mocks_directory)
////     |> mode(recorder.Record)
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
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode as d
import gleam/erlang/atom
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request
import gleam/int
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
/// - `body`: The complete response body, as the exact bytes the server sent.
///   A body is not always text: it can be an image, a PDF, or text in
///   another encoding. Use `body_text()` to read it as a UTF-8 string.
///
/// ## Example
///
/// ### Match on the response <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_describe_response.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{HttpResponse}
/// import gleam/bit_array
/// import gleam/int
///
/// pub fn describe_response(request: client.ClientRequest) -> String {
///   case client.send(request) {
///     Ok(HttpResponse(status: 200, body: body, ..)) ->
///       "OK: " <> int.to_string(bit_array.byte_size(body)) <> " bytes"
///     Ok(HttpResponse(status: status, ..)) -> "Status " <> int.to_string(status)
///     Error(_) -> "Request failed"
///   }
/// }
/// ```
pub type HttpResponse {
  HttpResponse(status: Int, headers: List(Header), body: BitArray)
}

/// Read the body of a response as text
///
/// ## Parameters
///
/// - `response`: The response to read
///
/// ## Returns
///
/// - `Ok(String)`: The body, when it is valid UTF-8
/// - `Error(Nil)`: The body is not valid UTF-8. Read `response.body` for
///   the bytes.
///
/// ## Example
///
/// ### Read the body as text <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_body_text.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn text_of(response: client.HttpResponse) -> String {
///   case client.body_text(response) {
///     Ok(text) -> text
///     Error(Nil) -> "The body is not text"
///   }
/// }
/// ```
pub fn body_text(response: HttpResponse) -> Result(String, Nil) {
  bit_array.to_string(response.body)
}

/// An HTTP/2 error code, as RFC 9113 section 7 defines them.
///
/// A server sends one in a RST_STREAM or a GOAWAY frame to say why it ends a
/// stream or a connection. `StreamReset`, `Goaway` and `ConnectionError` of
/// `TransportError` carry it.
///
/// ## Variants
///
/// - `NoError` — No error. A server uses it for a graceful shutdown.
/// - `ProtocolError` — The peer broke the HTTP/2 protocol.
/// - `InternalError` — The peer had an internal error.
/// - `FlowControlError` — The peer broke the flow control rules.
/// - `SettingsTimeout` — A SETTINGS frame got no answer in time.
/// - `StreamClosed` — A frame arrived for a stream that was closed.
/// - `FrameSizeError` — A frame had a size that is not valid.
/// - `RefusedStream` — The server refused the stream before it did any work
///   for it. The request is safe to send again.
/// - `Cancel` — The stream is no longer needed.
/// - `CompressionError` — The header compression state is broken.
/// - `ConnectError` — The connection for a CONNECT request failed.
/// - `EnhanceYourCalm` — The peer makes too much load.
/// - `InadequateSecurity` — The transport does not meet the security needs.
/// - `Http11Required` — The server needs HTTP/1.1 for this request.
/// - `UnknownErrorCode` — A code that is not one of these. `name` is the
///   name that gun gives it.
///
/// ## Example
///
/// ### Explain a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_transport_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type TransportError, ConnectFailed, Goaway, NoError, RefusedStream,
///   StreamReset, TimedOut, transport_error_to_string,
/// }
/// import gleam/int
///
/// pub fn explain(error: TransportError) -> String {
///   case error {
///     ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
///     TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
///     StreamReset(code: RefusedStream, ..) -> "The server refused the request"
///     Goaway(code: NoError, ..) -> "The server is going away"
///     _ -> transport_error_to_string(error)
///   }
/// }
/// ```
pub type Http2ErrorCode {
  NoError
  ProtocolError
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
  UnknownErrorCode(name: String)
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
///   error code (e.g. `InternalError`, `Cancel`, `RefusedStream`,
///   `EnhanceYourCalm`). The `description` field is gun's human-readable
///   explanation.
///
/// - `Goaway` — HTTP/2 GOAWAY frame. The server takes no new requests on the
///   connection. The client sends the request once more on another
///   connection, so this error comes back only when that also fails. The
///   `code` field is the HTTP/2 error code and `description` is gun's
///   human-readable explanation.
///
/// - `ConnectionError` — Connection-level protocol error. The `code` field is
///   the HTTP/2 error code and `description` is gun's human-readable
///   explanation.
///
/// - `RemoteClosed` — The remote peer closed the connection without sending
///   an explicit error code. If it closed before the response head, the
///   server can have processed the request. So the client sends a GET, HEAD,
///   OPTIONS, TRACE, PUT or DELETE request once more on another connection,
///   and this error comes back only when that also fails. It sends a POST,
///   PATCH or other request only once (RFC 9110, section 9.2.2).
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
/// - `NoRecording` — The request has a recorder in playback mode, and no
///   recording matches it. The client sends nothing to the network.
///   `method` is the method in upper case, for example `"GET"`, and `url`
///   is the URL of the request after the recorder's request transformer:
///   the scheme, the host, the port when the request sets one, the path and
///   the query. `directory` is the directory that the recorder searched.
///   `nearest` holds at most 3 recordings with the same method and path,
///   nearest first: see `recorder.NearestRecording` and the recording guide
///   for the rule.
///
/// ## Example
///
/// ### Explain a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_transport_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type TransportError, ConnectFailed, Goaway, NoError, RefusedStream,
///   StreamReset, TimedOut, transport_error_to_string,
/// }
/// import gleam/int
///
/// pub fn explain(error: TransportError) -> String {
///   case error {
///     ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
///     TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
///     StreamReset(code: RefusedStream, ..) -> "The server refused the request"
///     Goaway(code: NoError, ..) -> "The server is going away"
///     _ -> transport_error_to_string(error)
///   }
/// }
/// ```
pub type TransportError {
  StreamReset(code: Http2ErrorCode, description: String)
  Goaway(code: Http2ErrorCode, description: String)
  ConnectionError(code: Http2ErrorCode, description: String)
  RemoteClosed
  TimedOut(timeout_ms: Int)
  ProcessDown(reason: String)
  ConnectFailed(reason: String)
  Unexpected(raw: String)
  NoRecording(
    method: String,
    url: String,
    directory: String,
    nearest: List(recorder.NearestRecording),
  )
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
/// `NoRecording` is the one error with more lines. The first line names the
/// request. Then each nearest recording shows its path and the parts that
/// differ, with the recorded value on a `-` line and the requested value on
/// a `+` line. With no nearest recording, the second line names the
/// directory that the recorder searched.
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
      "Stream reset (" <> http2_error_code_name(code) <> "): " <> description
    Goaway(code: code, description: description) ->
      "GOAWAY (" <> http2_error_code_name(code) <> "): " <> description
    ConnectionError(code: code, description: description) ->
      "Connection error ("
      <> http2_error_code_name(code)
      <> "): "
      <> description
    RemoteClosed -> "Remote closed connection"
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    ProcessDown(reason: reason) -> "Process down: " <> reason
    ConnectFailed(reason: reason) -> "Connection failed: " <> reason
    Unexpected(raw: raw) -> "Unexpected error: " <> raw
    NoRecording(
      method: method,
      url: url,
      directory: directory,
      nearest: nearest,
    ) ->
      "No recording matches "
      <> method
      <> " "
      <> url
      <> "\n"
      <> describe_nearest(directory, nearest)
  }
}

// The nearest recordings of a playback miss, one block for each, or the
// directory that has no recording with the method and path.
fn describe_nearest(
  directory: String,
  nearest: List(recorder.NearestRecording),
) -> String {
  case nearest {
    [] -> "No recording in " <> directory <> " has this method and path"
    [first, ..rest] ->
      [
        describe_candidate("Nearest recording: ", first),
        ..list.map(rest, describe_candidate("Next nearest recording: ", _))
      ]
      |> string.join("\n")
  }
}

fn describe_candidate(
  label: String,
  candidate: recorder.NearestRecording,
) -> String {
  [
    label <> candidate.path,
    ..list.flat_map(candidate.differences, describe_difference)
  ]
  |> string.join("\n")
}

fn describe_difference(difference: recorder.Difference) -> List(String) {
  [
    "  " <> part_name(difference.part) <> ":",
    "  - " <> shown_value(difference.recorded),
    "  + " <> shown_value(difference.requested),
  ]
}

fn part_name(part: recorder.RequestPart) -> String {
  case part {
    recorder.Origin -> "origin"
    recorder.Query -> "query"
    recorder.Header(name: name) -> "header " <> name
    recorder.Body -> "body"
  }
}

fn shown_value(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> "(none)"
  }
}

// The name of an HTTP/2 error code for a message, in the lowercase form
// that RFC 9113 names have in logs.
fn http2_error_code_name(code: Http2ErrorCode) -> String {
  case code {
    NoError -> "no_error"
    ProtocolError -> "protocol_error"
    InternalError -> "internal_error"
    FlowControlError -> "flow_control_error"
    SettingsTimeout -> "settings_timeout"
    StreamClosed -> "stream_closed"
    FrameSizeError -> "frame_size_error"
    RefusedStream -> "refused_stream"
    Cancel -> "cancel"
    CompressionError -> "compression_error"
    ConnectError -> "connect_error"
    EnhanceYourCalm -> "enhance_your_calm"
    InadequateSecurity -> "inadequate_security"
    Http11Required -> "http_1_1_required"
    UnknownErrorCode(name: name) -> name
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
      "HTTP "
      <> int.to_string(response.status)
      <> ": "
      <> body_for_display(response.body)
    TransportFailure(error: error) -> transport_error_to_string(error)
  }
}

// A body as text for a message. A body that is not UTF-8 has no text form,
// so the message gives its size.
fn body_for_display(body: BitArray) -> String {
  case bit_array.to_string(body) {
    Ok(text) -> text
    Error(Nil) ->
      "<" <> int.to_string(bit_array.byte_size(body)) <> " bytes, not UTF-8>"
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

/// Minimum log level for dream_http_client's own log output.
///
/// Every log line of the client goes through one Erlang module,
/// `dream_http_client_log`, and this setting is the OTP logger module level
/// of that module (`logger:set_module_level/2`). It changes only the lines of
/// the client: the primary logger level and the logging of the rest of your
/// application stay the same.
///
/// ## Variants
///
/// - `LogDebug` — Every line. The client writes no debug lines, so this shows
///   the same lines as `LogInfo`.
/// - `LogInfo` — Info lines and warnings. The info line is
///   `[dream_http] connection closed: ...`, when a server closes an idle
///   connection.
/// - `LogWarning` — Warnings only (default): a connection that went down while a
///   request was on it, a body that the client cannot decompress, an unknown
///   content encoding, a recorder that does not answer, a recording that
///   cannot be read correctly, and a recorded stream that failed.
/// - `LogError` — Errors only. The client writes no error lines, so this
///   shows nothing.
/// - `LogNone` — No lines.
///
/// ## Example
///
/// ### Show the info lines <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{LogInfo}
///
/// pub fn info_lines() -> Nil {
///   client.transport_config()
///   |> client.log_level(LogInfo)
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
    body: BitArray,
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
    pool: Option(ConnectionPool),
  )
}

/// A connection pool of its own for some requests.
///
/// Make one with `new_pool()`, keep it, and give it to requests with
/// `pool()`. Requests share connections only with requests that have the
/// same pool. The pool opens at most its `max_connections` connections to
/// each host.
///
/// The value is opaque. A pool has one limit, set when it is made, so two
/// requests cannot give the same pool different limits.
///
/// ## Example
///
/// ### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn model_pool() -> client.ConnectionPool {
///   client.new_pool(max_connections: 3)
/// }
///
/// pub fn model_request(
///   pool: client.ConnectionPool,
///   prompt: String,
/// ) -> client.ClientRequest {
///   client.new()
///   |> client.host("api.llm.example")
///   |> client.path("/v1/chat")
///   |> client.body(prompt)
///   |> client.pool(pool)
/// }
///
/// pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
///   client.get_pool(request)
///   |> option.map(client.get_pool_max_connections)
/// }
/// ```
pub opaque type ConnectionPool {
  ConnectionPool(id: reference.Reference, max_connections: Int)
}

/// Make a connection pool
///
/// Make a pool one time, for example when the application starts, and keep
/// the value with the other services of the application. Each call makes a
/// new pool with its own connections, so a pool made for each request would
/// never use a connection again.
///
/// ## Parameters
///
/// - `max_connections`: The most connections the pool opens to one host
///
/// ## Returns
///
/// A new pool with no connections. The pool opens a connection when a
/// request needs one.
///
/// ## Example
///
/// ### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn model_pool() -> client.ConnectionPool {
///   client.new_pool(max_connections: 3)
/// }
///
/// pub fn model_request(
///   pool: client.ConnectionPool,
///   prompt: String,
/// ) -> client.ClientRequest {
///   client.new()
///   |> client.host("api.llm.example")
///   |> client.path("/v1/chat")
///   |> client.body(prompt)
///   |> client.pool(pool)
/// }
///
/// pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
///   client.get_pool(request)
///   |> option.map(client.get_pool_max_connections)
/// }
/// ```
pub fn new_pool(max_connections max_connections: Int) -> ConnectionPool {
  ConnectionPool(id: reference.new(), max_connections:)
}

/// Get the connection limit of a pool
///
/// ## Parameters
///
/// - `pool`: The pool to read
///
/// ## Returns
///
/// The most connections the pool opens to one host.
///
/// ## Example
///
/// ### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn model_pool() -> client.ConnectionPool {
///   client.new_pool(max_connections: 3)
/// }
///
/// pub fn model_request(
///   pool: client.ConnectionPool,
///   prompt: String,
/// ) -> client.ClientRequest {
///   client.new()
///   |> client.host("api.llm.example")
///   |> client.path("/v1/chat")
///   |> client.body(prompt)
///   |> client.pool(pool)
/// }
///
/// pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
///   client.get_pool(request)
///   |> option.map(client.get_pool_max_connections)
/// }
/// ```
pub fn get_pool_max_connections(pool: ConnectionPool) -> Int {
  pool.max_connections
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
    body: <<>>,
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
    pool: None,
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
/// requests. For JSON, serialize your data first. For a body that is not
/// text, such as a file, use `body_bits()`.
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
  ClientRequest(..client_request, body: <<body_value:utf8>>)
}

/// Set the body for the request as bytes
///
/// Sets the request body to the exact bytes of `body_value`. Use it for a
/// body that is not text: a file, an image, or text in an encoding that is
/// not UTF-8. For text, `body()` is shorter.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `body_value`: The request body as bytes
///
/// ## Returns
///
/// A new `ClientRequest` with the body updated.
///
/// ## Example
///
/// ### Upload a file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_body_bits.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/http
///
/// pub fn upload_request(file: BitArray) -> client.ClientRequest {
///   client.new()
///   |> client.method(http.Put)
///   |> client.host("files.example.com")
///   |> client.path("/reports/2026.pdf")
///   |> client.add_header("Content-Type", "application/pdf")
///   |> client.body_bits(file)
/// }
/// ```
pub fn body_bits(
  client_request: ClientRequest,
  body_value: BitArray,
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
///     |> mode(recorder.Record)
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
/// pub fn fetch_with_connect_timeout() -> Result(BitArray, client.SendError) {
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

/// Send this request through a connection pool of its own
///
/// Without this setting, every request uses the default pool, and
/// `max_connections()` of the transport config limits the connections to
/// each host. With it, the request shares connections only with requests
/// that have the same pool, and that pool opens at most its own
/// `max_connections` connections to each host. A busy caller with a pool of
/// its own does not use up the connections of other callers, and a small
/// limit holds one caller back without a change for the others.
///
/// When every connection of the pool is full, the request waits for room up
/// to its timeout, and then fails with `TimedOut`. On HTTP/2, one
/// connection carries as many requests as the server allows, so the limit
/// is on connections, not on requests.
///
/// ## Parameters
///
/// - `client_request`: The request to modify
/// - `pool`: A pool from `new_pool()`
///
/// ## Returns
///
/// The request with the pool set.
///
/// ## Example
///
/// ### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn model_pool() -> client.ConnectionPool {
///   client.new_pool(max_connections: 3)
/// }
///
/// pub fn model_request(
///   pool: client.ConnectionPool,
///   prompt: String,
/// ) -> client.ClientRequest {
///   client.new()
///   |> client.host("api.llm.example")
///   |> client.path("/v1/chat")
///   |> client.body(prompt)
///   |> client.pool(pool)
/// }
///
/// pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
///   client.get_pool(request)
///   |> option.map(client.get_pool_max_connections)
/// }
/// ```
pub fn pool(
  client_request: ClientRequest,
  pool: ConnectionPool,
) -> ClientRequest {
  ClientRequest(..client_request, pool: option.Some(pool))
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
/// - keepalive: 30_000ms (HTTP/2 ping interval)
/// - keepalive_tolerance: 3 (unack'd pings before disconnect)
/// - max_concurrent_streams: 100 (the HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS
///   value that the client sends to the server)
/// - initial_connection_window_size: 65_535 (HTTP/2 connection flow control)
/// - initial_stream_window_size: 65_535 (HTTP/2 per-stream flow control)
/// - closing_timeout: 15_000ms (graceful shutdown wait)
/// - log_level: LogWarning (minimum severity for dream log output: warnings
///   only. The application starts with this level, and a server that closes
///   an idle connection writes no line)
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
    keepalive: 30_000,
    keepalive_tolerance: 3,
    max_concurrent_streams: 100,
    initial_connection_window_size: 65_535,
    initial_stream_window_size: 65_535,
    closing_timeout: 15_000,
    log_level: LogWarning,
    default_certificate_authority_file: None,
  )
}

/// Set maximum TCP connections per host
///
/// Controls how many simultaneous TCP connections can be open to a single
/// host. With HTTP/2, a single connection supports multiplexed streams,
/// so fewer connections are needed than with HTTP/1.1.
///
/// An HTTP/1.1 connection carries one request at a time. An HTTP/2
/// connection carries as many streams as the server allows with
/// `SETTINGS_MAX_CONCURRENT_STREAMS`. The pool opens a new connection only
/// when every connection to the host is full. When `count` connections are
/// full, a new request waits for room up to its timeout, and then fails
/// with `TimedOut`.
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
/// Longer timeouts improve connection reuse but consume resources. A
/// connection that serves a response, for example a long stream, is not
/// idle and stays open. The pool checks for idle connections once per
/// timeout, so an idle connection closes between one and two timeouts after
/// its last use. A new value applies at once: `configure_transport` makes
/// the pool replace the check that it scheduled with the old value.
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

/// Set the HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS value that the client sends
///
/// gun sends this value to the server in the client's SETTINGS frame: it is
/// the number of streams that the server may open to the client at once. It
/// does not limit the requests of the client. The pool puts requests on an
/// HTTP/2 connection up to the limit that the server sends in its own
/// SETTINGS frame.
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

/// Set the minimum log level for dream_http_client's own log output
///
/// Every log line of the client goes through one module, and this level
/// applies to all of them (see `LogLevel` for what each level shows). It is
/// the OTP logger module level of that module (`logger:set_module_level/2`),
/// so it does not change the logging of the rest of your application. The
/// level applies when `configure_transport` returns.
///
/// ## Parameters
///
/// - `config`: The transport config to modify
/// - `level`: Minimum log level (default: `LogWarning`)
///
/// ## Example
///
/// ### Show the info lines <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{LogInfo}
///
/// pub fn info_lines() -> Nil {
///   client.transport_config()
///   |> client.log_level(LogInfo)
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

/// Get the HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS value that the client sends
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
/// Only messages at this level or above are output. The default is
/// `LogWarning`.
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
/// The client reads the next chunk from the server only after the callback
/// returns (at most 16 chunks wait in memory). A slow callback slows the
/// server down and does not fill memory. The request timeout measures the
/// server, not the callback.
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
/// Returns the request body as bytes. A body set with `body()` is the UTF-8
/// bytes of its string.
///
/// ## Example
///
/// ### Read the body <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_get_body.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
///
/// pub fn request_body() -> BitArray {
///   let request = client.new() |> client.body("{\"name\": \"Alice\"}")
///   client.get_body(request)
/// }
/// ```
pub fn get_body(client_request: ClientRequest) -> BitArray {
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

/// Get the connection pool of the request
///
/// ## Parameters
///
/// - `client_request`: The request to read
///
/// ## Returns
///
/// `Some(ConnectionPool)` when `pool()` set one, and `None` for a request
/// that uses the default pool.
///
/// ## Example
///
/// ### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/option.{type Option}
///
/// pub fn model_pool() -> client.ConnectionPool {
///   client.new_pool(max_connections: 3)
/// }
///
/// pub fn model_request(
///   pool: client.ConnectionPool,
///   prompt: String,
/// ) -> client.ClientRequest {
///   client.new()
///   |> client.host("api.llm.example")
///   |> client.path("/v1/chat")
///   |> client.body(prompt)
///   |> client.pool(pool)
/// }
///
/// pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
///   client.get_pool(request)
///   |> option.map(client.get_pool_max_connections)
/// }
/// ```
pub fn get_pool(client_request: ClientRequest) -> Option(ConnectionPool) {
  client_request.pool
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
///     |> mode(recorder.Record)
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

/// Identifies one stream that `stream_to()` started
///
/// `stream_to()` returns a `RequestId`, and every `StreamMessage` of that
/// stream carries the same value in its `request_id` field. Compare the two
/// with `==` to tell apart the messages of streams that send to one inbox.
/// Give it to `cancel_stream()` to stop the stream.
///
/// ## Notes
///
/// - The type is opaque. Only `stream_to()` makes a `RequestId`, and its
///   contents can change in any release.
/// - Two streams never have the same `RequestId` in one VM. A `RequestId`
///   means nothing in another VM or after a restart.
///
/// ## Example
///
/// ### Match a message to its stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_id.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/erlang/process
/// import gleam/http
/// import gleam/result
///
/// pub fn first_message_is_ours() -> Result(Bool, String) {
///   let inbox = process.new_subject()
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/fast")
///   use request_id <- result.try(client.stream_to(request, inbox))
///   let first_message = process.receive(inbox, 5000)
///   client.cancel_stream(request_id)
///   case first_message {
///     // Every message of the stream carries the id that stream_to returned
///     Ok(message) -> Ok(message.request_id == request_id)
///     Error(Nil) -> Error("No message within 5 seconds")
///   }
/// }
/// ```
///
/// ## See Also
///
/// - `stream_to()`: starts a stream and returns its `RequestId`
/// - `cancel_stream()`: stops the stream of a `RequestId`
pub opaque type RequestId {
  RequestId(stream: process.Pid)
}

/// A message that a stream of `stream_to()` sends to its inbox
///
/// A stream sends its messages to the inbox in this order:
///
/// 1. `StreamStart`: once, when the response headers arrive
/// 2. `Chunk`: zero or more times, one for each part of the body, in order
/// 3. `StreamEnd` or `StreamError`: exactly one of them, as the last message
///
/// A stream that fails before the response headers arrive, for example
/// because the connection is refused, sends only one `StreamError`. After
/// the last message, or after `cancel_stream()` returns, the stream sends
/// nothing more.
///
/// Every message carries the `RequestId` that `stream_to()` returned, so
/// `message.request_id` works on each message.
///
/// ## Example
///
/// ### Handle stream messages in an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L50-L67"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// fn handle_stream_message(
///   state: State,
///   message: StreamMessage,
/// ) -> actor.Next(State, StreamMessage) {
///   case message {
///     StreamStart(..) -> actor.continue(state)
///     Chunk(data: data, ..) ->
///       actor.continue(State(..state, body: bit_array.append(state.body, data)))
///     StreamEnd(..) -> {
///       process.send(state.done, Ok(state.body))
///       actor.stop()
///     }
///     StreamError(error: error, ..) -> {
///       process.send(state.done, Error(stream_failure_to_string(error)))
///       actor.stop()
///     }
///   }
/// }
/// ```
///
/// ## See Also
///
/// - `stream_to()`: starts a stream that sends these messages
/// - `stream_failure_to_string()`: describes the failure of a `StreamError`
pub type StreamMessage {
  /// The response headers arrived. Body chunks can follow.
  StreamStart(request_id: RequestId, headers: List(Header))
  /// The next part of the response body.
  Chunk(request_id: RequestId, data: BitArray)
  /// The body is complete. `headers` holds the trailing headers, and is
  /// empty when the response has none.
  StreamEnd(request_id: RequestId, headers: List(Header))
  /// The stream failed: a non-2xx response (`HttpFailure`), or a transport
  /// failure such as a refused connection, a dropped connection or a
  /// timeout (`TransportFailure`). No message follows it.
  StreamError(request_id: RequestId, error: StreamFailure)
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
/// a network call. A request that no recording matches returns
/// `Error(RequestError(NoRecording(method, url, directory, nearest)))` and is not sent.
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
/// ### Send and handle errors <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_send.gleam#L5-L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   RequestError, ResponseError, host, path, port, scheme, send,
///   transport_error_to_string,
/// }
/// import gleam/http
/// import gleam/int
/// import gleam/result
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
///     Ok(response) ->
///       client.body_text(response)
///       |> result.replace_error("The body is not text")
///     Error(ResponseError(response: response)) ->
///       Error("HTTP error " <> int.to_string(response.status))
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

  case ask_recorder(recorder_instance, recorded_request) {
    PlayRecording(response) -> handle_recorded_blocking_response(response)
    SendLive ->
      send_and_maybe_record(client_request, recorder_instance, recorded_request)
    RecorderFailure(error) -> Error(RequestError(error: error))
  }
}

/// What the recorder of a request says to do with it.
type RecorderAnswer {
  /// A recording matches: play its response back.
  PlayRecording(response: recording.RecordedResponse)
  /// No recording matches, and the recorder is not in playback mode: send
  /// the request to the network (and record it in record mode).
  SendLive
  /// Fail with this error, and send nothing to the network: no recording
  /// matches in playback mode (`NoRecording`), or the lookup failed.
  RecorderFailure(error: TransportError)
}

/// The one place that decides how a request with a recorder is answered.
/// `send`, `stream_yielder`, `start_stream` and `stream_to` all use it.
fn ask_recorder(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
) -> RecorderAnswer {
  case recorder.find_recording(recorder_instance, recorded_request) {
    Ok(option.Some(recording.Recording(_, response))) -> PlayRecording(response)
    Ok(option.None) ->
      answer_without_recording(recorder_instance, recorded_request)
    Error(reason) -> RecorderFailure(Unexpected(raw: reason))
  }
}

// In playback mode the request fails with the nearest recordings, and in
// the other modes it goes to the network.
fn answer_without_recording(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
) -> RecorderAnswer {
  case recorder.playback_miss(recorder_instance, recorded_request) {
    option.Some(miss) ->
      RecorderFailure(NoRecording(
        method: miss.method,
        url: miss.url,
        directory: miss.directory,
        nearest: miss.nearest,
      ))
    option.None -> SendLive
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
      |> result.map_error(fn(reason) { RequestError(Unexpected(raw: reason)) })
      |> result.try(fn(_saved) { response_result(status, headers, body) })
    }
    Error(error) -> Error(RequestError(error: error))
  }
}

// In record mode, saves the response and returns when it is on disk. A
// failed write is the error of the call.
fn record_response_if_needed(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> Result(Nil, String) {
  case recorder.is_record_mode(recorder_instance) {
    True -> {
      let recorder_entry =
        recording.Recording(request: recorded_request, response: response)
      recorder.add_recording(recorder_instance, recorder_entry)
    }
    False -> Ok(Nil)
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
) -> Result(#(Int, List(#(String, String)), BitArray), TransportError) {
  let http_request = to_http_request(client_request)
  let url = build_url(http_request)
  let method_atom = internal.atomize_method(http_request.method)
  let method_dynamic = atom.to_dynamic(method_atom)
  let body = http_request.body
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
}

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
    pool: option.map(request.pool, fn(pool) { #(pool.id, pool.max_connections) }),
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
///   capturing timing information between chunks for realistic replay. The
///   recording has the status that the server sent. A stream that fails is
///   not saved, because playback would show its first part as a whole
///   response.
/// - **Playback mode**: Yields recorded chunks from the fixture file, each
///   after its recorded delay. The timeout of the request limits each wait,
///   as in a live stream: a longer delay yields a `TimedOut` failure. A
///   recording with a status outside 2xx yields one `HttpFailure` with the
///   recorded status, headers and body, as a live stream does. No network
///   calls are made. A request that no recording matches yields one
///   `TransportFailure(NoRecording(method, url, directory, nearest))`, and is not sent.
///
/// The same `StreamingResponse` fixture format is shared with `start_stream()`,
/// so recordings made with either function can be played back by both.
///
/// ## Flow Control
///
/// The client reads the response from the server only as fast as you take
/// chunks from the yielder. At most 16 chunks wait in memory. The rest of the
/// response waits in the network, so a slow reader of a large response does
/// not fill memory.
///
/// ## Error Semantics
///
/// The yielder produces `Result(BytesTree, StreamFailure)` for each chunk:
/// - `Ok(chunk)` - Successful chunk, more may follow
/// - `Error(failure)` - **Terminal error**, stream is done
///
/// After an `Error`, the yielder returns `Done` on the next call. It does not
/// send the request again, and the connection goes back to the pool. So
/// `yielder.to_list` and `yielder.fold` return on a stream that fails, and
/// the list ends with the one `Error`. HTTP stream errors (timeouts,
/// connection drops, etc.) are **not recoverable** - you cannot continue
/// reading from a broken stream.
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

  case ask_recorder(recorder_instance, recorded_request) {
    PlayRecording(response) ->
      yielder.unfold(
        YielderPlaybackNotStarted(
          playback: recorded_playback(response),
          timeout_ms: resolve_timeout(client_request),
        ),
        next_yielder_step,
      )
    SendLive -> create_stream_yielder_from_client_request(client_request)
    RecorderFailure(error) -> yielder.single(Error(TransportFailure(error:)))
  }
}

fn create_stream_yielder_from_client_request(
  client_request: ClientRequest,
) -> yielder.Yielder(Result(bytes_tree.BytesTree, StreamFailure)) {
  let pull_request =
    PullRequest(
      http_req: to_http_request(client_request),
      timeout_ms: resolve_timeout(client_request),
      connect_timeout_ms: resolve_connect_timeout(client_request),
      auto_redirect: resolve_auto_redirect(client_request),
      connection_settings: resolve_connection_settings(client_request),
    )
  let stream_recording =
    option.then(client_request.recorder, fn(recorder_instance) {
      new_stream_recording(
        recorder_instance,
        client_request_to_recorded_request(client_request),
      )
    })
  yielder.unfold(
    YielderNotStarted(request: pull_request, recording: stream_recording),
    next_yielder_step,
  )
}

// The request of a pull stream that has not started yet.
type PullRequest {
  PullRequest(
    http_req: request.Request(BitArray),
    timeout_ms: Int,
    connect_timeout_ms: Int,
    auto_redirect: Bool,
    connection_settings: internal.ConnectionSettings,
  )
}

// The state of the yielder of stream_yielder().
//
// - `YielderNotStarted`: no request went out yet. The first step sends it.
// - `YielderStreaming`: `owner` is the stream owner process of a running
//   stream.
// - `YielderFailed`: the yielder yielded an `Error`. The stream owner gave
//   the lease back and stopped, so the next step is `Done`, and no request
//   goes out again.
//
// - `YielderPlaybackNotStarted`: playback of a recording, before the first
//   step.
// - `YielderPlayback`: playback of a recording. `chunks` are the chunks that
//   did not come yet, and `previous_due` is the time in milliseconds when
//   the previous chunk was due.
//
// A stream that ends normally needs no state: its step is `Done`.
// `recording` is the stream that a recorder in record mode saves when the
// stream ends. A stream that fails is not saved.
type YielderState {
  YielderNotStarted(request: PullRequest, recording: Option(StreamRecording))
  YielderStreaming(owner: process.Pid, recording: Option(StreamRecording))
  YielderFailed
  YielderPlaybackNotStarted(playback: Playback, timeout_ms: Int)
  YielderPlayback(
    chunks: List(recording.Chunk),
    previous_due: Int,
    timeout_ms: Int,
  )
}

fn next_yielder_step(
  state: YielderState,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case state {
    YielderNotStarted(request: pull_request, recording: stream_recording) ->
      start_yielder_stream(pull_request, stream_recording)
    YielderStreaming(owner: owner, recording: stream_recording) ->
      yield_next_event(owner, stream_recording)
    YielderFailed -> yielder.Done
    YielderPlaybackNotStarted(playback: playback, timeout_ms: timeout_ms) ->
      start_yielder_playback(playback, timeout_ms)
    YielderPlayback(
      chunks: chunks,
      previous_due: previous_due,
      timeout_ms: timeout_ms,
    ) -> yield_recorded_chunk(chunks, previous_due, timeout_ms)
  }
}

// The first chunk is due after its delay, counted from the first step: a
// live stream also sends its request at the first step.
fn start_yielder_playback(
  playback: Playback,
  timeout_ms: Int,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case playback {
    PlaybackFailure(failure) -> yielder.Next(Error(failure), YielderFailed)
    PlaybackStream(headers: _, chunks: chunks) ->
      yield_recorded_chunk(chunks, get_time_ms(), timeout_ms)
  }
}

// Waits until the next chunk is due, in the process that reads the
// yielder, and yields it. Playback starts no process, so a reader that
// stops reading leaves no wait behind.
fn yield_recorded_chunk(
  chunks: List(recording.Chunk),
  previous_due: Int,
  timeout_ms: Int,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case chunks {
    [] -> yielder.Done
    [chunk, ..rest] -> {
      let due = previous_due + chunk.delay_ms
      let wait = recorded_chunk_wait(due, timeout_ms)
      process.sleep(wait_milliseconds(wait))
      yield_after_wait(wait, chunk, rest, due, timeout_ms)
    }
  }
}

fn yield_after_wait(
  wait: RecordedChunkWait,
  chunk: recording.Chunk,
  rest: List(recording.Chunk),
  due: Int,
  timeout_ms: Int,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case wait {
    ChunkAfter(_wait_ms) ->
      yielder.Next(
        Ok(bytes_tree.from_bit_array(chunk.data)),
        YielderPlayback(chunks: rest, previous_due: due, timeout_ms: timeout_ms),
      )
    TimeoutAfter(timeout_ms: waited_ms) ->
      yielder.Next(Error(recorded_timeout(waited_ms)), YielderFailed)
  }
}

fn start_yielder_stream(
  pull_request: PullRequest,
  stream_recording: Option(StreamRecording),
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  let owner =
    internal.start_gun_stream(
      pull_request.http_req,
      pull_request.timeout_ms,
      pull_request.connect_timeout_ms,
      pull_request.auto_redirect,
      pull_request.connection_settings,
    )
  case stream_recording {
    None -> yield_next_event(owner, None)
    Some(state) -> yield_first_recorded_event(owner, state)
  }
}

// A recorded stream saves the status and the headers of the response, so
// it gets them before the first event. A stream that did not start gives
// its failure here.
fn yield_first_recorded_event(
  owner: process.Pid,
  stream_recording: StreamRecording,
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case internal.fetch_start_headers(owner) {
    Ok(#(status, headers)) ->
      yield_next_event(
        owner,
        Some(
          StreamRecording(..stream_recording, status: status, headers: headers),
        ),
      )
    Error(failure) -> yielder.Next(Error(failure), YielderFailed)
  }
}

fn yield_next_event(
  owner: process.Pid,
  stream_recording: Option(StreamRecording),
) -> yielder.Step(Result(bytes_tree.BytesTree, StreamFailure), YielderState) {
  case internal.fetch_next(owner) {
    internal.Chunk(data) ->
      yielder.Next(
        Ok(bytes_tree.from_bit_array(data)),
        YielderStreaming(
          owner: owner,
          recording: record_stream_chunk(stream_recording, data),
        ),
      )
    // The saved headers of a yielder stream are the response headers. The
    // stream ends when its recording is on disk; a failed write is the
    // last item of the yielder.
    internal.Done(_trailers) ->
      case record_stream_end(stream_recording, []) {
        Ok(Nil) -> yielder.Done
        Error(failure) -> yielder.Next(Error(failure), YielderFailed)
      }
    // The stream owner gave the lease back and stopped before it gave the
    // failure.
    internal.Failed(failure) -> yielder.Next(Error(failure), YielderFailed)
  }
}

fn to_http_request(client_request: ClientRequest) -> request.Request(BitArray) {
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
  body: BitArray,
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

// Saves a streamed response and returns when it is on disk.
// `reversed_chunks` holds the chunks newest first.
fn save_stream_recording(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
  status: Int,
  headers: List(#(String, String)),
  reversed_chunks: List(recording.Chunk),
) -> Result(Nil, String) {
  let response =
    recording.StreamingResponse(
      status: status,
      headers: headers,
      chunks: list.reverse(reversed_chunks),
    )

  recorder.add_recording(
    recorder_instance,
    recording.Recording(request: recorded_request, response: response),
  )
}

// Starts the low-level HTTP stream via gun. A translator process sends the
// stream to the calling process as `{http, TranslatorMessage}` messages.
// Returns the translator.
fn start_stream_messages(client_request: ClientRequest) -> process.Pid {
  let http_request = to_http_request(client_request)
  internal.start_stream_messages(
    internal.atomize_method(http_request.method),
    build_url(http_request),
    http_request.headers,
    http_request.body,
    resolve_timeout(client_request),
    resolve_connect_timeout(client_request),
    resolve_auto_redirect(client_request),
    resolve_connection_settings(client_request),
  )
}

fn build_url(request: request.Request(BitArray)) -> String {
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

// A message from the translator process of a stream. The Erlang shim builds
// these values, for example `{translator_chunk, Data}`.
type TranslatorMessage {
  TranslatorStart(status: Int, headers: List(Header))
  TranslatorChunk(data: BitArray)
  TranslatorEnd(headers: List(Header))
  TranslatorError(failure: StreamFailure)
}

// A message that a stream process receives.
type StreamProcessMessage {
  FromTranslator(message: TranslatorMessage)
  OwnerStopped
}

// What a stream process does with the stream: call the callbacks of
// start_stream(), or send messages to the inbox of stream_to().
type StreamHandlers {
  StreamHandlers(
    on_start: fn(List(Header)) -> Nil,
    on_chunk: fn(BitArray) -> Nil,
    on_end: fn(List(Header)) -> Nil,
    on_error: fn(StreamFailure) -> Nil,
  )
}

// A stream that a recorder in record mode saves when the stream ends.
// `chunks` holds the chunks newest first.
type StreamRecording {
  StreamRecording(
    recorder: recorder.Recorder,
    recorded_request: recording.RecordedRequest,
    status: Int,
    headers: List(#(String, String)),
    chunks: List(recording.Chunk),
    last_chunk_time: Option(Int),
  )
}

fn select_translator_messages(
  selector: process.Selector(StreamProcessMessage),
) -> process.Selector(StreamProcessMessage) {
  process.select_record(
    selector,
    tag: atom.create("http"),
    fields: 1,
    mapping: translator_message,
  )
}

// The selector gives the whole `{http, TranslatorMessage}` record.
fn translator_message(record: d.Dynamic) -> StreamProcessMessage {
  FromTranslator(message: record_element(2, record))
}

@external(erlang, "erlang", "element")
fn record_element(index: Int, record: d.Dynamic) -> TranslatorMessage

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
/// - **Playback mode**: Replays recorded chunks via your callbacks:
///   `on_stream_start`, then `on_stream_chunk` for each chunk after its
///   recorded delay, then `on_stream_end`. The timeout of the request limits
///   each wait, as in a live stream: a longer delay calls `on_stream_error`
///   with a `TimedOut` failure. A recording with a status outside 2xx calls
///   only `on_stream_error`, with an `HttpFailure` that holds the recorded
///   status, headers and body. No network calls are made. A request that
///   no recording matches calls only `on_stream_error`, with
///   `TransportFailure(NoRecording(method, url, directory, nearest))`, and is not sent.
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
  let stream_pid =
    process.spawn_unlinked(fn() {
      run_stream_process(
        request,
        callback_handlers(request),
        process.new_selector(),
      )
    })

  Ok(StreamHandle(pid: stream_pid))
}

/// Start an HTTP stream that sends typed messages to an inbox
///
/// Starts the stream in its own process and returns its `RequestId` at once
/// (non-blocking). The stream sends `StreamMessage` values to `inbox`:
/// `StreamStart`, then a `Chunk` for each part of the body, then exactly one
/// `StreamEnd` or `StreamError`. Each message carries the returned
/// `RequestId`. Only `inbox` gets messages: no untyped message reaches the
/// mailbox of your process.
///
/// Use this in an OTP actor. Add `inbox` to the selector of the actor with
/// `process.select`, and handle the stream messages like any other actor
/// message. Use `start_stream()` when callbacks that run in the stream
/// process are enough. `stream_to()` does not call the `on_stream_*`
/// callbacks of `request`.
///
/// ## Ownership
///
/// The process that calls `stream_to()` owns the stream. When that process
/// stops, the stream stops too and sends nothing more. A `start_stream()`
/// stream is different: it keeps running after the process that started it
/// stops.
///
/// ## Recording and Playback
///
/// When a recorder is attached (via `recorder()`), `stream_to()` works like
/// `start_stream()`:
///
/// - **Record mode**: Streams from the real server, sends the messages, and
///   saves the stream in the `StreamingResponse` fixture format that
///   `start_stream()` and `stream_yielder()` use. The stream is saved before
///   its `StreamEnd` or `StreamError` message is sent. A cancelled stream is
///   not saved.
/// - **Playback mode**: Sends `StreamStart` with the recorded headers, a
///   `Chunk` for each recorded chunk after its recorded delay, then
///   `StreamEnd(request_id, [])`. A blocking recording is sent as one chunk.
///   The timeout of the request limits each wait, as in a live stream: a
///   longer delay sends `StreamError` with a `TimedOut` failure. A recording
///   with a status outside 2xx sends only `StreamError`, with an
///   `HttpFailure` that holds the recorded status, headers and body. No
///   network calls are made. A request that no recording matches sends only
///   `StreamError` with `TransportFailure(NoRecording(method, url, directory, nearest))`, and
///   is not sent.
///
/// ## Parameters
///
/// - `request`: The configured HTTP request
/// - `inbox`: The subject that gets the stream messages. The process that
///   created it receives them.
///
/// ## Returns
///
/// - `Ok(RequestId)`: The stream started. Every message of the stream
///   carries this `RequestId`.
/// - `Error(String)`: The same shape as `start_stream()`. It is not returned
///   today: a stream that cannot connect, or that gets an error response,
///   sends a `StreamError` to `inbox`.
///
/// ## Example
///
/// ### Stream into an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L5-L75"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client.{
///   type StreamMessage, Chunk, StreamEnd, StreamError, StreamStart, host, path,
///   port, scheme, stream_failure_to_string, stream_to,
/// }
/// import gleam/bit_array
/// import gleam/erlang/process.{type Subject}
/// import gleam/http
/// import gleam/otp/actor
/// import gleam/result
///
/// pub type State {
///   State(body: BitArray, done: Subject(Result(BitArray, String)))
/// }
///
/// pub fn download_body() -> Result(BitArray, String) {
///   let done = process.new_subject()
///   use _started <- result.try(
///     actor.new_with_initialiser(1000, fn(_self) { start_download(done) })
///     |> actor.on_message(handle_stream_message)
///     |> actor.start
///     |> result.map_error(describe_start_error),
///   )
///   case process.receive(done, 10_000) {
///     Ok(body_result) -> body_result
///     Error(Nil) -> Error("The download did not end within 10 seconds")
///   }
/// }
///
/// fn start_download(
///   done: Subject(Result(BitArray, String)),
/// ) -> Result(actor.Initialised(State, StreamMessage, Nil), String) {
///   let inbox = process.new_subject()
///   let request =
///     client.new()
///     |> scheme(http.Http)
///     |> host("localhost")
///     |> port(9876)
///     |> path("/stream/fast")
///   // The actor owns the stream: the stream stops when the actor stops
///   use _request_id <- result.map(stream_to(request, inbox))
///   let selector = process.new_selector() |> process.select(inbox)
///   actor.initialised(State(body: <<>>, done: done))
///   |> actor.selecting(selector)
/// }
///
/// fn handle_stream_message(
///   state: State,
///   message: StreamMessage,
/// ) -> actor.Next(State, StreamMessage) {
///   case message {
///     StreamStart(..) -> actor.continue(state)
///     Chunk(data: data, ..) ->
///       actor.continue(State(..state, body: bit_array.append(state.body, data)))
///     StreamEnd(..) -> {
///       process.send(state.done, Ok(state.body))
///       actor.stop()
///     }
///     StreamError(error: error, ..) -> {
///       process.send(state.done, Error(stream_failure_to_string(error)))
///       actor.stop()
///     }
///   }
/// }
///
/// fn describe_start_error(error: actor.StartError) -> String {
///   case error {
///     actor.InitTimeout -> "The download actor did not start in time"
///     actor.InitFailed(reason) -> reason
///     actor.InitExited(_reason) -> "The download actor stopped while it started"
///   }
/// }
/// ```
///
/// ## See Also
///
/// - `cancel_stream()`: stops the stream
/// - `StreamMessage`: the messages and their order
/// - `start_stream()`: a stream with callbacks
pub fn stream_to(
  request: ClientRequest,
  inbox: process.Subject(StreamMessage),
) -> Result(RequestId, String) {
  let owner = process.self()
  let stream_pid =
    process.spawn_unlinked(fn() {
      let owner_monitor = process.monitor(owner)
      let owner_selector =
        process.new_selector()
        |> process.select_specific_monitor(owner_monitor, fn(_down) {
          OwnerStopped
        })
      let handlers = inbox_handlers(inbox, RequestId(stream: process.self()))
      run_stream_process(request, handlers, owner_selector)
    })

  Ok(RequestId(stream: stream_pid))
}

fn callback_handlers(request: ClientRequest) -> StreamHandlers {
  StreamHandlers(
    on_start: option.unwrap(request.on_stream_start, ignore_headers),
    on_chunk: option.unwrap(request.on_stream_chunk, ignore_chunk),
    on_end: option.unwrap(request.on_stream_end, ignore_headers),
    on_error: option.unwrap(request.on_stream_error, ignore_failure),
  )
}

fn ignore_headers(_headers: List(Header)) -> Nil {
  Nil
}

fn ignore_chunk(_data: BitArray) -> Nil {
  Nil
}

fn ignore_failure(_failure: StreamFailure) -> Nil {
  Nil
}

fn inbox_handlers(
  inbox: process.Subject(StreamMessage),
  request_id: RequestId,
) -> StreamHandlers {
  StreamHandlers(
    on_start: fn(headers) {
      process.send(inbox, StreamStart(request_id: request_id, headers: headers))
    },
    on_chunk: fn(data) {
      process.send(inbox, Chunk(request_id: request_id, data: data))
    },
    on_end: fn(headers) {
      process.send(inbox, StreamEnd(request_id: request_id, headers: headers))
    },
    on_error: fn(error) {
      process.send(inbox, StreamError(request_id: request_id, error: error))
    },
  )
}

// Runs one stream in the calling process. `stop_selector` selects the
// messages that stop a live stream early.
fn run_stream_process(
  request: ClientRequest,
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
) -> Nil {
  case request.recorder {
    None -> stream_live(request, handlers, stop_selector, None)
    Some(recorder_instance) ->
      stream_with_recorder(request, handlers, stop_selector, recorder_instance)
  }
}

fn stream_with_recorder(
  request: ClientRequest,
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
  recorder_instance: recorder.Recorder,
) -> Nil {
  let recorded_request = client_request_to_recorded_request(request)
  case ask_recorder(recorder_instance, recorded_request) {
    PlayRecording(response) ->
      replay_recorded_stream(
        handlers,
        stop_selector,
        recorded_playback(response),
        resolve_timeout(request),
      )
    SendLive ->
      stream_live(
        request,
        handlers,
        stop_selector,
        new_stream_recording(recorder_instance, recorded_request),
      )
    RecorderFailure(error) -> handlers.on_error(TransportFailure(error:))
  }
}

fn new_stream_recording(
  recorder_instance: recorder.Recorder,
  recorded_request: recording.RecordedRequest,
) -> Option(StreamRecording) {
  case recorder.is_record_mode(recorder_instance) {
    True ->
      Some(StreamRecording(
        recorder: recorder_instance,
        recorded_request: recorded_request,
        status: 0,
        headers: [],
        chunks: [],
        last_chunk_time: None,
      ))
    False -> None
  }
}

fn stream_live(
  request: ClientRequest,
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
  stream_recording: Option(StreamRecording),
) -> Nil {
  let selector = select_translator_messages(stop_selector)
  let translator = start_stream_messages(request)
  process_stream_loop(selector, translator, handlers, stream_recording)
}

// What playback of a recorded response gives a stream.
//
// - `PlaybackFailure`: the recorded status is outside 2xx. A live stream
//   gives `HttpFailure` with the whole body, and no chunk.
// - `PlaybackStream`: the recorded status is 2xx. A blocking recording is
//   one chunk with no delay.
type Playback {
  PlaybackFailure(failure: StreamFailure)
  PlaybackStream(headers: List(Header), chunks: List(recording.Chunk))
}

fn recorded_playback(response: recording.RecordedResponse) -> Playback {
  case response {
    recording.StreamingResponse(status, headers, chunks) ->
      playback_of(status, headers, chunks)
    recording.BlockingResponse(status, headers, body) ->
      playback_of(status, headers, [recording.Chunk(data: body, delay_ms: 0)])
  }
}

// The same rule as the live stream in dream_http_shim: a status from 200
// to 299 starts a stream, and any other status is an `HttpFailure` with
// the status, the headers and the whole body.
fn playback_of(
  status: Int,
  headers: List(#(String, String)),
  chunks: List(recording.Chunk),
) -> Playback {
  case status >= 200 && status < 300 {
    True -> PlaybackStream(headers: tuples_to_headers(headers), chunks: chunks)
    False ->
      PlaybackFailure(
        HttpFailure(response: HttpResponse(
          status: status,
          headers: tuples_to_headers(headers),
          body: bit_array.concat(list.map(chunks, fn(chunk) { chunk.data })),
        )),
      )
  }
}

// The wait for the next recorded chunk.
//
// The `delay_ms` of a recorded chunk is the time from the arrival of the
// previous chunk to its own arrival. So a chunk is due `delay_ms` after the
// previous chunk was due, and playback waits only for the time that is
// left: a slow chunk handler does not make the stream slower than the
// recording. As in a live stream, the timeout of the request limits each
// wait for the next chunk.
type RecordedChunkWait {
  // The chunk comes after `wait_ms`.
  ChunkAfter(wait_ms: Int)
  // The timeout ends the wait first: after `timeout_ms`, the stream fails
  // with `TimedOut`.
  TimeoutAfter(timeout_ms: Int)
}

fn recorded_chunk_wait(due: Int, timeout_ms: Int) -> RecordedChunkWait {
  let wait_ms = int.max(due - get_time_ms(), 0)
  case wait_ms > timeout_ms {
    True -> TimeoutAfter(timeout_ms: timeout_ms)
    False -> ChunkAfter(wait_ms: wait_ms)
  }
}

fn wait_milliseconds(wait: RecordedChunkWait) -> Int {
  case wait {
    ChunkAfter(wait_ms: wait_ms) -> wait_ms
    TimeoutAfter(timeout_ms: timeout_ms) -> timeout_ms
  }
}

// The failure of a live stream that got no data within the timeout.
fn recorded_timeout(timeout_ms: Int) -> StreamFailure {
  TransportFailure(error: TimedOut(timeout_ms: timeout_ms))
}

// Plays back a recording through the stream handlers. The first chunk is
// due after its delay, counted from the start.
fn replay_recorded_stream(
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
  playback: Playback,
  timeout_ms: Int,
) -> Nil {
  case playback {
    PlaybackFailure(failure) -> handlers.on_error(failure)
    PlaybackStream(headers: headers, chunks: chunks) -> {
      let started = get_time_ms()
      handlers.on_start(headers)
      replay_recorded_chunks(
        handlers,
        stop_selector,
        chunks,
        started,
        timeout_ms,
      )
    }
  }
}

// Each wait is a receive with a timeout on `stop_selector`, so a stream of
// stream_to() stops in a wait when its owner stops. A cancel kills the
// stream process, also in a wait.
fn replay_recorded_chunks(
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
  chunks: List(recording.Chunk),
  previous_due: Int,
  timeout_ms: Int,
) -> Nil {
  case chunks {
    [] -> handlers.on_end([])
    [chunk, ..rest] -> {
      let due = previous_due + chunk.delay_ms
      let wait = recorded_chunk_wait(due, timeout_ms)
      case process.selector_receive(stop_selector, wait_milliseconds(wait)) {
        Ok(_owner_stopped) -> Nil
        Error(Nil) ->
          replay_after_wait(
            handlers,
            stop_selector,
            wait,
            chunk,
            rest,
            due,
            timeout_ms,
          )
      }
    }
  }
}

fn replay_after_wait(
  handlers: StreamHandlers,
  stop_selector: process.Selector(StreamProcessMessage),
  wait: RecordedChunkWait,
  chunk: recording.Chunk,
  rest: List(recording.Chunk),
  due: Int,
  timeout_ms: Int,
) -> Nil {
  case wait {
    ChunkAfter(_wait_ms) -> {
      handlers.on_chunk(chunk.data)
      replay_recorded_chunks(handlers, stop_selector, rest, due, timeout_ms)
    }
    TimeoutAfter(timeout_ms: waited_ms) ->
      handlers.on_error(recorded_timeout(waited_ms))
  }
}

// The translator always ends the stream with a TranslatorEnd or a
// TranslatorError message: after the timeout of the request, the stream
// ends with a TimedOut failure. A stream of stream_to() also stops when its
// owner stops. The recording is updated before the handler runs, so a
// recording is saved before the end of the stream is reported.
//
// The translator sends the next chunk only after `grant_next`, which this
// loop calls when the chunk handler returned. A slow handler slows the
// server down, and no chunks collect in the mailbox.
fn process_stream_loop(
  selector: process.Selector(StreamProcessMessage),
  translator: process.Pid,
  handlers: StreamHandlers,
  stream_recording: Option(StreamRecording),
) -> Nil {
  case process.selector_receive_forever(selector) {
    FromTranslator(TranslatorStart(status, headers)) -> {
      let updated = record_stream_start(stream_recording, status, headers)
      handlers.on_start(headers)
      process_stream_loop(selector, translator, handlers, updated)
    }
    FromTranslator(TranslatorChunk(data)) -> {
      let updated = record_stream_chunk(stream_recording, data)
      handlers.on_chunk(data)
      internal.grant_next(translator)
      process_stream_loop(selector, translator, handlers, updated)
    }
    FromTranslator(TranslatorEnd(headers)) ->
      case record_stream_end(stream_recording, headers) {
        Ok(Nil) -> handlers.on_end(headers)
        Error(failure) -> handlers.on_error(failure)
      }
    FromTranslator(TranslatorError(failure)) -> {
      record_stream_error(stream_recording, failure)
      handlers.on_error(failure)
    }
    OwnerStopped -> Nil
  }
}

fn record_stream_start(
  stream_recording: Option(StreamRecording),
  status: Int,
  headers: List(Header),
) -> Option(StreamRecording) {
  option.map(stream_recording, fn(state) {
    StreamRecording(
      ..state,
      status: status,
      headers: headers_to_tuples(headers),
    )
  })
}

fn record_stream_chunk(
  stream_recording: Option(StreamRecording),
  data: BitArray,
) -> Option(StreamRecording) {
  option.map(stream_recording, fn(state) {
    add_recorded_chunk(state, data, get_time_ms())
  })
}

fn add_recorded_chunk(
  state: StreamRecording,
  data: BitArray,
  now: Int,
) -> StreamRecording {
  let delay = case state.last_chunk_time {
    Some(last_time) -> now - last_time
    None -> 0
  }
  StreamRecording(
    ..state,
    chunks: [recording.Chunk(data: data, delay_ms: delay), ..state.chunks],
    last_chunk_time: Some(now),
  )
}

// Saves the recording of a stream that ended, and returns when it is on
// disk. A failed write is a `TransportFailure` with `Unexpected`.
fn record_stream_end(
  stream_recording: Option(StreamRecording),
  trailers: List(Header),
) -> Result(Nil, StreamFailure) {
  case stream_recording {
    Some(state) ->
      save_stream_recording(
        state.recorder,
        state.recorded_request,
        state.status,
        recorded_end_headers(state.headers, trailers),
        state.chunks,
      )
      |> result.map_error(fn(reason) {
        TransportFailure(error: Unexpected(raw: reason))
      })
    None -> Ok(Nil)
  }
}

// The saved headers are the trailing headers when the response has some,
// and the response headers otherwise.
fn recorded_end_headers(
  headers: List(#(String, String)),
  trailers: List(Header),
) -> List(#(String, String)) {
  case trailers {
    [] -> headers
    _ -> headers_to_tuples(trailers)
  }
}

// A stream that failed is not complete, so it is not saved. Playback would
// show the part that arrived as a whole response.
fn record_stream_error(
  stream_recording: Option(StreamRecording),
  failure: StreamFailure,
) -> Nil {
  case stream_recording {
    Some(_state) ->
      internal.log_warning(
        "HTTP stream error while recording a stream, so the recording is not saved: "
        <> stream_failure_to_string(failure),
      )
    None -> Nil
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

/// Stop a stream that `stream_to()` started
///
/// Stops the stream process of `request_id` and waits until it has stopped.
/// The request is cancelled: over HTTP/2 the server gets a stream reset,
/// and over HTTP/1.1 the pooled connection reads and drops the rest of the
/// body before it can serve another request. When `cancel_stream()`
/// returns, the stream sends no more messages to its inbox. Messages that the stream sent before the cancel can still wait in
/// the mailbox of the process that owns the inbox.
///
/// A cancel of a stream that has already ended, or a second cancel of the
/// same stream, does nothing and returns `Nil`. Any process can cancel a
/// stream, not only its owner. In record mode, a cancelled stream is not
/// saved.
///
/// ## Parameters
///
/// - `request_id`: The `RequestId` that `stream_to()` returned
///
/// ## Returns
///
/// `Nil`, after the stream has stopped.
///
/// ## Example
///
/// ### Cancel a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_cancel_stream.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import gleam/erlang/process
/// import gleam/http
/// import gleam/result
///
/// pub fn start_then_cancel() -> Result(Nil, String) {
///   let inbox = process.new_subject()
///   let request =
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/stream/fast")
///   use request_id <- result.map(client.stream_to(request, inbox))
///   // Later: no message of this stream comes after the cancel
///   client.cancel_stream(request_id)
/// }
/// ```
///
/// ## See Also
///
/// - `stream_to()`: starts a stream and returns its `RequestId`
/// - `cancel_stream_handle()`: stops a stream of `start_stream()`
pub fn cancel_stream(request_id: RequestId) -> Nil {
  let RequestId(stream: stream_pid) = request_id
  let stream_monitor = process.monitor(stream_pid)
  process.kill(stream_pid)
  process.new_selector()
  |> process.select_specific_monitor(stream_monitor, fn(_down) { Nil })
  |> process.selector_receive_forever
}
