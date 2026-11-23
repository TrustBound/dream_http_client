//// Internal utilities for HTTP client
////
//// This module provides internal utilities for the HTTP client, including
//// Erlang externals and low-level stream handling. These functions are used
//// internally by the public API and should not be used directly by application
//// code.
////
//// This is an internal module. Use `dream_http_client/client`,
//// `dream_http_client/recorder`, and `dream_http_client/matching` instead.

import gleam/erlang/atom
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/option
import gleam/string

/// The settings that decide which connection a request uses
///
/// `protocols` is the protocol preference (`default`, `http1_only`,
/// `http2_only` or `http2_preferred`). `certificate_authority_file` is the
/// PEM file of the certificate authorities to trust over TLS, in place of the
/// system ones. `None` uses the client-wide default, and if that is not set,
/// the system certificate authorities.
pub type ConnectionSettings {
  ConnectionSettings(
    protocols: atom.Atom,
    certificate_authority_file: option.Option(String),
    pool: option.Option(#(reference.Reference, Int)),
  )
}

/// One event of a pull-based stream, as the stream owner process gives it
///
/// `failure` is `client.StreamFailure`. The type is a parameter because this
/// module cannot import `client`.
///
/// - `Chunk`: the next part of the body.
/// - `Done`: the body is complete. `trailers` holds the trailing headers.
/// - `Failed`: the stream failed.
pub type StreamEvent(failure) {
  Chunk(data: BitArray)
  Done(trailers: List(#(String, String)))
  Failed(failure: failure)
}

@external(erlang, "dream_http_shim", "request_stream")
fn request_stream(
  method: atom.Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
  connect_timeout_ms: Int,
  autoredirect: Bool,
  connection_settings: ConnectionSettings,
) -> process.Pid

/// Get the next event of a stream that `start_gun_stream` started
///
/// Waits until the stream owner process has the next event. The owner
/// gives a `TimedOut` failure when no data comes within the timeout of the
/// request.
@external(erlang, "dream_http_shim", "fetch_next")
pub fn fetch_next(owner: process.Pid) -> StreamEvent(failure)

/// Get the response headers of a stream that `start_gun_stream` started
///
/// Returns the failure of the stream when the response did not start.
@external(erlang, "dream_http_shim", "fetch_start_headers")
pub fn fetch_start_headers(
  owner: process.Pid,
) -> Result(#(Int, List(#(String, String))), failure)

/// Convert an HTTP method to an Erlang atom
///
/// Converts a Gleam HTTP method type to an Erlang atom for use with the
/// Erlang gun library. This is an internal function used by the streaming
/// request implementation.
///
/// ## Parameters
///
/// - `method`: The HTTP method to convert
///
/// ## Returns
///
/// An Erlang atom representing the HTTP method (e.g., `"get"`, `"post"`).
pub fn atomize_method(method: http.Method) -> atom.Atom {
  case method {
    http.Get -> atom.create("get")
    http.Post -> atom.create("post")
    http.Put -> atom.create("put")
    http.Delete -> atom.create("delete")
    http.Patch -> atom.create("patch")
    http.Head -> atom.create("head")
    http.Options -> atom.create("options")
    http.Trace -> atom.create("trace")
    http.Connect -> atom.create("connect")
    http.Other(method_string) -> atom.create(string.lowercase(method_string))
  }
}

/// Start an HTTP streaming request
///
/// Starts a stream owner process that sends the request, follows redirects
/// and collects the body. Use `fetch_next` with the returned PID to get the
/// body, and `fetch_start_headers` to get the response headers.
///
/// ## Parameters
///
/// - `request`: The HTTP request to send
/// - `timeout_ms`: Timeout in milliseconds for the request
/// - `connect_timeout_ms`: Timeout in milliseconds for the connection
/// - `autoredirect`: Whether to follow redirects
/// - `connection_settings`: The protocols and certificate authorities to use
///
/// ## Returns
///
/// The PID of the stream owner process.
pub fn start_gun_stream(
  request: Request(BitArray),
  timeout_ms: Int,
  connect_timeout_ms: Int,
  autoredirect: Bool,
  connection_settings: ConnectionSettings,
) -> process.Pid {
  let port_string = case request.port {
    option.Some(port) -> ":" <> int.to_string(port)
    option.None -> ""
  }
  let query_string = case request.query {
    option.Some(query) -> "?" <> query
    option.None -> ""
  }
  let url =
    http.scheme_to_string(request.scheme)
    <> "://"
    <> request.host
    <> port_string
    <> request.path
    <> query_string
  request_stream(
    atomize_method(request.method),
    url,
    request.headers,
    request.body,
    timeout_ms,
    connect_timeout_ms,
    autoredirect,
    connection_settings,
  )
}

// ============================================================================
// Message-Based Streaming FFI
// ============================================================================

/// Start a message-based streaming HTTP request
///
/// Starts a translator process that sends the request and sends the stream
/// to the calling process (the stream process) as
/// `{http, TranslatorMessage}` messages: one start, zero or more chunks, then
/// one end or one error. The translator is linked to the calling process.
/// When the calling process stops, the translator cancels the request and
/// stops too.
///
/// **Note:** This is an internal function used by the public API. Use
/// `client.start_stream()` or `client.stream_to()` instead.
///
/// ## Parameters
///
/// - `method`: HTTP method as an Erlang atom (e.g., `atom.create("get")`)
/// - `url`: Full request URL (scheme://host:port/path?query)
/// - `headers`: List of HTTP header name-value pairs
/// - `body`: Request body as a `BitArray`
/// - `timeout_ms`: Request timeout in milliseconds
/// - `connect_timeout_ms`: Connection timeout in milliseconds
/// - `autoredirect`: Whether to follow redirects
/// - `connection_settings`: The protocols and certificate authorities to use
@external(erlang, "dream_http_shim", "request_stream_messages")
pub fn start_stream_messages(
  method: atom.Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout_ms: Int,
  connect_timeout_ms: Int,
  autoredirect: Bool,
  connection_settings: ConnectionSettings,
) -> process.Pid

/// Tell the translator of a message stream that the stream process handled
/// a chunk. The translator then lets gun read the next chunk from the
/// server.
@external(erlang, "dream_http_shim", "grant_next")
pub fn grant_next(translator: process.Pid) -> Nil
