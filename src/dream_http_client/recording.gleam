//// Recording format types and JSON codecs
////
//// Defines the structure for storing HTTP request/response recordings
//// in a custom JSON format that supports both blocking and streaming responses.

import dream_http_client/internal.{log_warning}
import gleam/bit_array.{base64_decode, base64_encode, from_string, to_string}
import gleam/dynamic/decode.{
  type Decoder, at, field, optional, optional_field, success, then,
}
import gleam/http.{
  type Method, type Scheme, Connect, Delete, Get, Head, Http, Https, Options,
  Other, Patch, Post, Put, Trace,
}
import gleam/json.{
  type Json, UnableToDecode, UnexpectedByte, UnexpectedEndOfInput,
  UnexpectedSequence, array, null, object, parse,
}
import gleam/list.{append, take}
import gleam/option.{type Option, None, Some}
import gleam/result.{map_error}
import gleam/string.{concat, join, lowercase, uppercase}

/// A recorded HTTP request
///
/// Captures all components of an HTTP request for recording and playback.
/// This type is used internally by the recorder to match incoming requests
/// against recorded ones.
///
/// ## Fields
///
/// - `method`: HTTP method (GET, POST, PUT, DELETE, etc.)
/// - `scheme`: Protocol scheme (HTTP or HTTPS)
/// - `host`: Server hostname or IP address
/// - `port`: Optional port number (None uses default: 80 for HTTP, 443 for HTTPS)
/// - `path`: Request path (e.g., "/api/users/123")
/// - `query`: Optional query string without the leading "?" (e.g., "page=1&limit=10")
/// - `headers`: List of header name-value pairs
/// - `body`: Request body as a string
///
/// ## Examples
///
/// ### Describe a request <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_request.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
/// import gleam/http
/// import gleam/option
///
/// pub fn user_request() -> recording.RecordedRequest {
///   recording.RecordedRequest(
///     method: http.Get,
///     scheme: http.Https,
///     host: "api.example.com",
///     port: option.None,
///     path: "/users/123",
///     query: option.Some("fields=name,email"),
///     headers: [#("Authorization", "Bearer token123")],
///     body: <<>>,
///   )
/// }
/// ```
pub type RecordedRequest {
  RecordedRequest(
    method: Method,
    scheme: Scheme,
    host: String,
    port: Option(Int),
    path: String,
    query: Option(String),
    headers: List(#(String, String)),
    body: BitArray,
  )
}

/// A recorded HTTP response
///
/// Represents either a blocking (complete) response or a streaming response
/// with chunks. This type captures the response data needed for playback.
///
/// ## Variants
///
/// - `BlockingResponse(status, headers, body)`: Complete response body received at once
/// - `StreamingResponse(status, headers, chunks)`: Response delivered in chunks with timing.
///   Playback of a status outside 2xx gives `HttpFailure` with the status,
///   the headers and all chunks joined as the body, as a live stream does.
///
/// ## Examples
///
/// ### Describe responses <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_response.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
///
/// pub fn blocking() -> recording.RecordedResponse {
///   recording.BlockingResponse(
///     status: 200,
///     headers: [#("Content-Type", "application/json")],
///     body: <<"{\"users\": []}">>,
///   )
/// }
///
/// pub fn streaming() -> recording.RecordedResponse {
///   recording.StreamingResponse(
///     status: 200,
///     headers: [#("Content-Type", "text/event-stream")],
///     chunks: [
///       recording.Chunk(data: <<"chunk1":utf8>>, delay_ms: 100),
///       recording.Chunk(data: <<"chunk2":utf8>>, delay_ms: 100),
///     ],
///   )
/// }
/// ```
pub type RecordedResponse {
  BlockingResponse(
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
  )
  StreamingResponse(
    status: Int,
    headers: List(#(String, String)),
    chunks: List(Chunk),
  )
}

/// A streaming chunk with timing information
///
/// Represents a single chunk of data from a streaming HTTP response, along with
/// the delay (in milliseconds) since the previous chunk. Playback uses this
/// timing to recreate the original streaming behavior: each chunk comes
/// `delay_ms` after the previous chunk came. The timeout of the request
/// limits each wait, as in a live stream. A delay longer than the timeout
/// ends the stream with a `TimedOut` failure.
///
/// ## Fields
///
/// - `data`: The chunk data as a `BitArray`
/// - `delay_ms`: Milliseconds from the arrival of the previous chunk to the
///   arrival of this chunk. Record mode saves 0 for the first chunk. In
///   playback, the delay of the first chunk counts from the start of the
///   stream.
///
/// ## Examples
///
/// ### Describe a chunk <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_chunk.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
///
/// pub fn greeting_chunk() -> recording.Chunk {
///   recording.Chunk(
///     data: <<"Hello, ":utf8>>,
///     // 50ms delay before this chunk
///     delay_ms: 50,
///   )
/// }
/// ```
pub type Chunk {
  Chunk(data: BitArray, delay_ms: Int)
}

/// A complete recording entry (request + response pair)
///
/// Represents a single recorded HTTP interaction: one request and its corresponding
/// response. Multiple `Recording` values are stored together in a `RecordingFile`.
///
/// ## Fields
///
/// - `request`: The recorded HTTP request
/// - `response`: The recorded HTTP response (blocking or streaming)
///
/// ## Examples
///
/// ### Pair a request with a response <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_recording.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
///
/// pub fn pair(
///   recorded_request: recording.RecordedRequest,
///   recorded_response: recording.RecordedResponse,
/// ) -> recording.Recording {
///   recording.Recording(request: recorded_request, response: recorded_response)
/// }
/// ```
pub type Recording {
  Recording(request: RecordedRequest, response: RecordedResponse)
}

/// Recording file format (versioned container)
///
/// The top-level structure for storing multiple recordings in a JSON file.
/// Includes a version field for future format compatibility and a list of
/// recording entries.
///
/// ## Fields
///
/// - `version`: Format version string (currently "1.0")
/// - `entries`: List of recording entries (request/response pairs)
///
/// ## Examples
///
/// ### Build a recording file <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_file.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
///
/// pub fn file_of(entries: List(recording.Recording)) -> recording.RecordingFile {
///   recording.RecordingFile(version: "1.0", entries: entries)
/// }
/// ```
///
/// ## Notes
///
/// - Version field allows future format changes while maintaining backward compatibility
/// - This type is primarily used internally by `encode_recording_file` and `decode_recording_file`
pub type RecordingFile {
  RecordingFile(version: String, entries: List(Recording))
}

// ============================================================================
// JSON Encoders
// ============================================================================

/// Encode a `RecordingFile` to JSON
///
/// Converts an in-memory `RecordingFile` value into a `json.Json` tree that can
/// be rendered to a string and written to disk. This function handles the JSON
/// encoding of all nested types (requests, responses, chunks, etc.).
///
/// ## Parameters
///
/// - `file`: The recording file to encode
///
/// ## Returns
///
/// A `json.Json` value representing the recording file structure, ready to be
/// serialized with `json.to_string()`.
///
/// ## Examples
///
/// ### Encode a recording file <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_encode.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
/// import gleam/json
///
/// pub fn to_json_string(entries: List(recording.Recording)) -> String {
///   let file = recording.RecordingFile(version: "1.0", entries: entries)
///   let json_value = recording.encode_recording_file(file)
///   // Now write the string to disk
///   json.to_string(json_value)
/// }
/// ```
///
/// ## Notes
///
/// - Most callers should use `storage.save_recordings()` instead of calling this directly
/// - This function is used internally by the storage module
/// - The JSON format includes a version field for future compatibility
pub fn encode_recording_file(file: RecordingFile) -> Json {
  let entries_json = list.map(file.entries, encode_recording)
  object([
    #("version", json.string(file.version)),
    #("entries", array(from: entries_json, of: identity_json)),
  ])
}

fn identity_json(value: Json) -> Json {
  value
}

fn encode_recording(recording: Recording) -> Json {
  object([
    #("request", encode_recorded_request(recording.request)),
    #("response", encode_recorded_response(recording.response)),
  ])
}

fn encode_recorded_request(req: RecordedRequest) -> Json {
  let port_json = case req.port {
    Some(p) -> json.int(p)
    None -> null()
  }
  let query_json = case req.query {
    Some(q) -> json.string(q)
    None -> null()
  }
  object(append(
    [
      #("method", encode_method(req.method)),
      #("scheme", encode_scheme(req.scheme)),
      #("host", json.string(req.host)),
      #("port", port_json),
      #("path", json.string(req.path)),
      #("query", query_json),
      #("headers", encode_headers(req.headers)),
    ],
    encode_body_fields(req.body),
  ))
}

fn encode_recorded_response(resp: RecordedResponse) -> Json {
  case resp {
    BlockingResponse(status, headers, body) ->
      object(append(
        [
          #("mode", json.string("blocking")),
          #("status", json.int(status)),
          #("headers", encode_headers(headers)),
        ],
        encode_body_fields(body),
      ))
    StreamingResponse(status, headers, chunks) -> {
      let chunks_json = list.map(chunks, encode_chunk)
      object([
        #("mode", json.string("streaming")),
        #("status", json.int(status)),
        #("headers", encode_headers(headers)),
        #("chunks", array(from: chunks_json, of: identity_json)),
      ])
    }
  }
}

/// Encode a request or response body for JSON storage.
///
/// JSON strings can only carry UTF-8, but a body can be any bytes:
/// S3 objects, PDFs, images. A body that is valid UTF-8 is stored as text,
/// so fixtures stay easy to read. Any other body is base64-encoded and
/// tagged with `"body_encoding": "base64"`, so the decoder restores the
/// exact bytes.
fn encode_body_fields(body: BitArray) -> List(#(String, Json)) {
  case to_string(body) {
    Ok(text) -> [#("body", json.string(text))]
    Error(Nil) -> [
      #("body", json.string(base64_encode(body, True))),
      #("body_encoding", json.string("base64")),
    ]
  }
}

fn encode_chunk(chunk: Chunk) -> Json {
  // Chunk data is a BitArray and may hold raw binary. UTF-8 chunks are
  // stored verbatim (keeps SSE fixtures human-readable); binary chunks
  // are base64-encoded and tagged with `"data_encoding": "base64"` —
  // never silently replaced with a placeholder.
  case to_string(chunk.data) {
    Ok(string_value) ->
      object([
        #("data", json.string(string_value)),
        #("delay_ms", json.int(chunk.delay_ms)),
      ])
    Error(_) ->
      object([
        #("data", json.string(base64_encode(chunk.data, True))),
        #("data_encoding", json.string("base64")),
        #("delay_ms", json.int(chunk.delay_ms)),
      ])
  }
}

fn encode_headers(headers: List(#(String, String))) -> Json {
  let header_arrays = list.map(headers, encode_header_pair)
  array(from: header_arrays, of: identity_json)
}

fn encode_header_pair(header: #(String, String)) -> Json {
  array(from: [json.string(header.0), json.string(header.1)], of: identity_json)
}

fn encode_method(method: Method) -> Json {
  let method_str = case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Delete -> "DELETE"
    Patch -> "PATCH"
    Head -> "HEAD"
    Options -> "OPTIONS"
    Trace -> "TRACE"
    Connect -> "CONNECT"
    Other(s) -> uppercase(s)
  }
  json.string(method_str)
}

fn encode_scheme(scheme: Scheme) -> Json {
  let scheme_str = case scheme {
    Http -> "http"
    Https -> "https"
  }
  json.string(scheme_str)
}

// ============================================================================
// JSON Decoders
// ============================================================================

/// Decode a JSON string into a `RecordingFile`
///
/// Parses a JSON string and decodes it into a `RecordingFile` value. This is
/// the inverse of `encode_recording_file()` and is used by the storage module
/// when loading recordings from disk.
///
/// ## Parameters
///
/// - `json_string`: The JSON string to decode (typically read from a file)
///
/// ## Returns
///
/// - `Ok(RecordingFile)`: Successfully decoded recording file
/// - `Error(String)`: Human-readable error message describing why decoding failed
///
/// ## Examples
///
/// ### Decode a recording file <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_recording_decode.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recording
/// import gleam/int
/// import gleam/list
/// import gleam/result
/// import gleam/string
/// import simplifile
///
/// pub fn count_entries(path: String) -> Result(String, String) {
///   // Read JSON from one recording file
///   use json_content <- result.try(
///     simplifile.read(path) |> result.map_error(string.inspect),
///   )
///
///   // Decode it to a RecordingFile (each file holds one entry)
///   case recording.decode_recording_file(json_content) {
///     Ok(file) ->
///       Ok(
///         "Loaded " <> int.to_string(list.length(file.entries)) <> " recording(s)",
///       )
///     Error(reason) -> Error("Failed to decode: " <> reason)
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Most callers should use `storage.load_recordings()` instead of calling this directly
/// - This function is used internally by the storage module
/// - Error messages include field paths to help identify decoding issues
/// - Handles both blocking and streaming response formats
pub fn decode_recording_file(
  json_string: String,
) -> Result(RecordingFile, String) {
  parse(json_string, decode_recording_file_decoder())
  |> map_error(format_json_error)
}

fn decode_recording_file_decoder() -> Decoder(RecordingFile) {
  use version <- field("version", decode.string)
  use entries <- field("entries", decode.list(decode_recording_decoder()))
  success(RecordingFile(version: version, entries: entries))
}

fn format_json_error(error: json.DecodeError) -> String {
  case error {
    UnexpectedEndOfInput -> "Unexpected end of JSON input"
    UnexpectedByte(msg) -> "Unexpected byte: " <> msg
    UnexpectedSequence(msg) -> "Unexpected sequence: " <> msg
    UnableToDecode(errors) -> format_decode_errors(errors)
  }
}

// decode.run gives at least one error. The message names the first one.
fn format_decode_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> take(1)
  |> list.map(format_single_decode_error)
  |> concat
}

fn format_single_decode_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected, found, path) = error
  let field_path = join(path, ".")
  "Expected " <> expected <> ", found " <> found <> " at " <> field_path
}

fn decode_recording_decoder() -> Decoder(Recording) {
  use request <- field("request", decode_recorded_request_decoder())
  use response <- field("response", decode_recorded_response_decoder())
  success(Recording(request: request, response: response))
}

fn decode_recorded_request_decoder() -> Decoder(RecordedRequest) {
  use method_str <- field("method", decode.string)
  use scheme_str <- field("scheme", decode.string)
  use host <- field("host", decode.string)
  use port <- field("port", optional(decode.int))
  use path <- field("path", decode.string)
  use query <- field("query", optional(decode.string))
  use headers <- field("headers", decode.list(decode_header_pair_decoder()))
  use stored_body <- field("body", decode.string)
  use body_encoding <- optional_field("body_encoding", "utf8", decode.string)
  let body = decode_stored_body(stored_body, body_encoding)

  // Parse method and scheme
  // Method: Use Other() for unknown methods (preserves original value)
  // Scheme: Fail on unknown schemes (only http/https are valid)
  let method = case parse_method_string(method_str) {
    Ok(parsed_method) -> parsed_method
    Error(parse_error) -> {
      // Preserve the original method string but log the parse error so it is
      // not silently discarded.
      log_warning("Failed to parse HTTP method in recording: " <> parse_error)
      Other(method_str)
    }
  }

  case parse_scheme_string(scheme_str) {
    Ok(scheme) ->
      success(RecordedRequest(
        method: method,
        scheme: scheme,
        host: host,
        port: port,
        path: path,
        query: query,
        headers: headers,
        body: body,
      ))
    Error(parse_error) -> {
      // Invalid scheme in recording - fall back to http and log the error so
      // it is visible when inspecting corrupted recording files.
      log_warning(
        "Unknown scheme in recording; defaulting to http: " <> parse_error,
      )
      success(RecordedRequest(
        method: method,
        scheme: Http,
        host: host,
        port: port,
        path: path,
        query: query,
        headers: headers,
        body: body,
      ))
    }
  }
}

fn decode_recorded_response_decoder() -> Decoder(RecordedResponse) {
  use mode <- field("mode", decode.string)
  use status <- field("status", decode.int)
  use headers <- field("headers", decode.list(decode_header_pair_decoder()))

  case mode {
    "blocking" -> decode_blocking_response_decoder(status, headers)
    "streaming" -> decode_streaming_response_decoder(status, headers)
    _ -> decode_blocking_response_decoder(status, headers)
  }
}

fn decode_blocking_response_decoder(
  status: Int,
  headers: List(#(String, String)),
) -> Decoder(RecordedResponse) {
  use stored_body <- field("body", decode.string)
  use body_encoding <- optional_field("body_encoding", "utf8", decode.string)
  success(BlockingResponse(
    status: status,
    headers: headers,
    body: decode_stored_body(stored_body, body_encoding),
  ))
}

/// Restore a stored request or response body to its original bytes. A body tagged
/// `"base64"` decodes to the exact recorded bytes. Any other body
/// (including fixtures written before the tag existed) is UTF-8 text. A
/// base64 body that cannot be decoded is an error in the fixture: the
/// stored text is used, and the error is logged.
fn decode_stored_body(stored: String, encoding: String) -> BitArray {
  case encoding {
    "base64" ->
      case base64_decode(stored) {
        Ok(bits) -> bits
        Error(_) -> {
          log_warning(
            "Recording body tagged base64 failed to decode; using raw value",
          )
          from_string(stored)
        }
      }
    _ -> from_string(stored)
  }
}

fn decode_streaming_response_decoder(
  status: Int,
  headers: List(#(String, String)),
) -> Decoder(RecordedResponse) {
  use chunks <- field("chunks", decode.list(decode_chunk_decoder()))
  success(StreamingResponse(status: status, headers: headers, chunks: chunks))
}

fn decode_chunk_decoder() -> Decoder(Chunk) {
  use data_str <- field("data", decode.string)
  use data_encoding <- optional_field("data_encoding", "utf8", decode.string)
  use delay_ms <- field("delay_ms", decode.int)
  let data = case data_encoding {
    "base64" ->
      case base64_decode(data_str) {
        Ok(bits) -> bits
        Error(_) -> {
          log_warning(
            "Recording chunk tagged base64 failed to decode; using raw value",
          )
          <<data_str:utf8>>
        }
      }
    _ -> <<data_str:utf8>>
  }
  success(Chunk(data: data, delay_ms: delay_ms))
}

fn decode_header_pair_decoder() -> Decoder(#(String, String)) {
  at([0], decode.string)
  |> then(build_header_value_decoder)
}

fn build_header_value_decoder(name: String) -> Decoder(#(String, String)) {
  at([1], decode.string)
  |> decode.map(build_header_pair(name))
}

fn build_header_pair(name: String) -> fn(String) -> #(String, String) {
  fn(value) { #(name, value) }
}

fn parse_method_string(method_str: String) -> Result(Method, String) {
  case lowercase(method_str) {
    "get" -> Ok(Get)
    "post" -> Ok(Post)
    "put" -> Ok(Put)
    "delete" -> Ok(Delete)
    "patch" -> Ok(Patch)
    "head" -> Ok(Head)
    "options" -> Ok(Options)
    "trace" -> Ok(Trace)
    "connect" -> Ok(Connect)
    _ -> Ok(Other(method_str))
  }
}

fn parse_scheme_string(scheme_str: String) -> Result(Scheme, String) {
  case scheme_str {
    "http" -> Ok(Http)
    "https" -> Ok(Https)
    _ -> Error("Unknown scheme: " <> scheme_str)
  }
}
