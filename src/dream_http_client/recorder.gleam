//// Recorder process and state management
////
//// Manages HTTP request/response recordings using a process to store state.
//// Supports recording, playback, and passthrough modes.

import dream_http_client/matching
import dream_http_client/recording
import dream_http_client/storage
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor.{type Next}
import gleam/result
import gleam/string

/// Opaque recorder handle for managing HTTP request/response recordings
///
/// A `Recorder` is a handle to an OTP actor process that manages recording state.
/// Multiple HTTP requests can share the same recorder by passing the same handle.
/// The recorder handles saving recordings to disk, loading them for playback,
/// and matching requests to recorded responses.
///
/// ## Thread Safety
///
/// Recorders are safe to use concurrently - multiple requests can use the same
/// recorder handle simultaneously. The internal actor processes messages sequentially.
///
/// ## Lifecycle
///
/// 1. Build with `recorder.new() |> ... |> start()`
/// 2. Attach to requests with `client.recorder(rec)`
/// 3. Optionally cleanup with `recorder.stop(rec)` (recordings already saved)
///
/// ## Examples
///
/// ### Record and stop <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_record_and_stop.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/http
/// import gleam/result
/// import gleam/string
///
/// pub fn record_and_stop(mocks_directory: String) -> Result(Nil, String) {
///   // Record mode
///   use rec <- result.try(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///
///   // Use the recorder with requests
///   use _response <- result.try(
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/text")
///     |> client.recorder(rec)
///     |> client.send()
///     |> result.map_error(string.inspect),
///   )
///
///   // Cleanup (optional: the recordings are already saved)
///   recorder.stop(rec)
/// }
/// ```
pub opaque type Recorder {
  Recorder(subject: process.Subject(RecorderMessage))
}

/// A request transformer applied before keying and persistence.
///
/// A transformer is a pure function `RecordedRequest -> RecordedRequest` that
/// runs in two places:
///
/// - Before computing the match key (so matching uses the transformed request)
/// - Before persisting recordings to disk (so secrets can be removed)
///
/// This is how you implement “scrub secrets and still match”: normalize the
/// request (remove auth headers, drop query params, normalize paths, etc.),
/// then choose a key that matches on the remaining stable fields.
///
/// ## Example (drop Authorization header)
///
/// ### Drop the Authorization header <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_request_transformer.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, request_transformer}
/// import dream_http_client/recording
/// import gleam/list
///
/// pub fn drop_auth_header(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   let headers =
///     request.headers
///     |> list.filter(fn(header) { header.0 != "Authorization" })
///   recording.RecordedRequest(..request, headers: headers)
/// }
///
/// pub fn scrubbing_builder() -> recorder.RecorderBuilder {
///   recorder.new()
///   |> mode("record")
///   |> directory("mocks")
///   |> request_transformer(drop_auth_header)
/// }
/// ```
pub type RequestTransformer =
  fn(recording.RecordedRequest) -> recording.RecordedRequest

/// A response transformer applied before persistence in Record mode.
///
/// This hook is for scrubbing secrets out of recorded responses (set-cookie,
/// authorization echoes, PII, etc.) before they are written to disk.
///
/// **Order of operations in Record mode:**
///
/// 1. The request transformer runs (request normalization + request scrubbing)
/// 2. The key is computed from the transformed request
/// 3. The response transformer runs (response scrubbing)
/// 4. The scrubbed recording is stored in memory and persisted to disk
///
/// Note: this transformer runs **only in Record mode**. Playback returns
/// whatever is in the saved fixtures.
pub type ResponseTransformer =
  fn(recording.RecordedRequest, recording.RecordedResponse) ->
    recording.RecordedResponse

/// Builder for configuring and starting a recorder.
///
/// Recorder configuration uses a builder so options can evolve without adding a
/// combinatorial set of `start_with_*` functions.
///
/// ## Fields
///
/// - `mode`: `"record"`, `"playback"` or `"passthrough"`, as set by `mode()`.
///   The default is `"passthrough"`.
/// - `directory`: the recordings directory. It is `None` until `directory()`
///   is called.
/// - `key`: the `MatchKey` that matches requests to recordings. The default
///   uses the method and the URL, as set by `key()`.
/// - `request_transformer`: changes each request before the key is computed
///   and before it is stored, as set by `request_transformer()`. The default
///   returns the request unchanged.
/// - `response_transformer`: changes each response before it is stored in
///   Record mode, as set by `response_transformer()`. The default returns the
///   response unchanged.
///
/// ### Build a playback recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode}
///
/// pub fn playback_builder() -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory("mocks/api")
///   |> mode("playback")
/// }
/// ```
pub type RecorderBuilder {
  RecorderBuilder(
    mode: String,
    directory: option.Option(String),
    key: matching.MatchKey,
    request_transformer: RequestTransformer,
    response_transformer: ResponseTransformer,
  )
}

/// Create a new recorder builder with safe defaults.
///
/// Defaults:
/// - `mode`: `"passthrough"`
/// - `directory`: unset
/// - `key`: `matching.request_key(method: True, url: True, headers: False, body: False)`
/// - `request_transformer`: identity
/// - `response_transformer`: identity
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn new() -> RecorderBuilder {
  RecorderBuilder(
    mode: "passthrough",
    directory: option.None,
    key: matching.request_key(
      method: True,
      url: True,
      headers: False,
      body: False,
    ),
    request_transformer: identity_request_transformer,
    response_transformer: identity_response_transformer,
  )
}

/// Set the recording directory used by `"record"` and `"playback"` modes.
///
/// The directory is **required** for `"record"` and `"playback"` (validated in
/// `start()`), and ignored for `"passthrough"`.
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn directory(
  builder: RecorderBuilder,
  directory: String,
) -> RecorderBuilder {
  RecorderBuilder(..builder, directory: option.Some(directory))
}

/// Set the recorder mode string.
///
/// Valid modes (validated in `start()`):
/// - `"record"`
/// - `"playback"`
/// - `"passthrough"`
///
/// Mode strings are case-sensitive.
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn mode(builder: RecorderBuilder, mode: String) -> RecorderBuilder {
  RecorderBuilder(..builder, mode: mode)
}

/// Set the match key function.
///
/// The key function determines how requests are grouped for playback lookup.
/// Keys should be stable and should generally **not** include secrets.
///
/// If two different recordings produce the same key, playback lookup becomes
/// ambiguous and `find_recording()` will return `Error(...)`.
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn key(
  builder: RecorderBuilder,
  key: matching.MatchKey,
) -> RecorderBuilder {
  RecorderBuilder(..builder, key: key)
}

/// Set the request transformer.
///
/// The transformer is applied before keying *and* before persistence, so it’s
/// the right place to normalize requests and scrub secrets.
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn request_transformer(
  builder: RecorderBuilder,
  request_transformer: RequestTransformer,
) -> RecorderBuilder {
  RecorderBuilder(..builder, request_transformer: request_transformer)
}

/// Set the response transformer.
///
/// This transformer is applied **only in Record mode** and runs before
/// persistence so recorded fixtures can be safely committed/shared.
///
/// ## Example
///
/// ### Build a record recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_builder_steps.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recorder.{
///   directory, key, mode, request_transformer, response_transformer,
/// }
/// import dream_http_client/recording
///
/// pub fn drop_headers(
///   request: recording.RecordedRequest,
/// ) -> recording.RecordedRequest {
///   recording.RecordedRequest(..request, headers: [])
/// }
///
/// pub fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
///   recorder.new()
///   |> directory(mocks_directory)
///   |> mode("record")
///   |> key(matching.request_key(
///     method: True,
///     url: True,
///     headers: False,
///     body: False,
///   ))
///   |> request_transformer(drop_headers)
///   |> response_transformer(drop_body)
/// }
/// ```
pub fn response_transformer(
  builder: RecorderBuilder,
  response_transformer: ResponseTransformer,
) -> RecorderBuilder {
  RecorderBuilder(..builder, response_transformer: response_transformer)
}

fn identity_request_transformer(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  request
}

fn identity_response_transformer(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  response
}

/// Recorder process state
type RecorderState {
  RecorderState(
    mode: RecorderMode,
    directory: String,
    key: matching.MatchKey,
    request_transformer: RequestTransformer,
    response_transformer: ResponseTransformer,
    recordings: dict.Dict(String, List(recording.Recording)),
  )
}

type RecorderMode {
  Record
  Playback
  Passthrough
}

/// Start a new recorder from a builder.
///
/// Creates an OTP actor process to manage recorder state. The recorder handles
/// saving recordings to disk (Record mode), loading them for playback (Playback mode),
/// or passing requests through unchanged (Passthrough mode).
///
/// ## Parameters
///
/// - `builder`: Recorder configuration builder
///
/// ## Returns
///
/// - `Ok(Recorder)`: Successfully started recorder
/// - `Error(String)`: Error message if startup fails (e.g., cannot load recordings in Playback mode)
///
/// ## Examples
///
/// ### Start a playback recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_start.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/result
///
/// pub fn start_playback(mocks_directory: String) -> Result(Bool, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("playback")
///     |> start(),
///   )
///   recorder.is_record_mode(rec)
/// }
/// ```
///
/// ## Notes
///
/// - In Playback mode, recordings are loaded from disk at startup
/// - In Record mode, recordings are saved immediately when captured (no need to call `stop()`)
/// - Multiple requests can share the same recorder handle safely
/// - The recorder process runs until `stop()` is called or the VM shuts down
pub fn start(builder: RecorderBuilder) -> Result(Recorder, String) {
  let mode = parse_mode(builder.mode)
  let directory = resolve_directory(mode, builder.directory)

  case mode, directory {
    Error(e), _ -> Error(e)
    _, Error(e) -> Error(e)
    Ok(parsed_mode), Ok(dir) -> {
      let initial_state =
        RecorderState(
          mode: parsed_mode,
          directory: dir,
          key: builder.key,
          request_transformer: builder.request_transformer,
          response_transformer: builder.response_transformer,
          recordings: dict.new(),
        )

      case parsed_mode {
        Playback -> {
          case storage.load_recordings(dir) {
            Ok(loaded) -> {
              let recordings_map =
                build_recordings_map(
                  loaded,
                  builder.key,
                  builder.request_transformer,
                )
              let state_with_recordings =
                RecorderState(
                  mode: parsed_mode,
                  directory: dir,
                  key: builder.key,
                  request_transformer: builder.request_transformer,
                  response_transformer: builder.response_transformer,
                  recordings: recordings_map,
                )
              actor.new(state_with_recordings)
              |> actor.on_message(handle_recorder_message)
              |> actor.start
              |> result.map(wrap_recorder_subject)
              |> result.map_error(string.inspect)
              |> result.map_error(string.append("Failed to start recorder: ", _))
            }
            Error(load_error) ->
              Error(
                "Failed to load recordings in playback mode: " <> load_error,
              )
          }
        }
        _ -> {
          actor.new(initial_state)
          |> actor.on_message(handle_recorder_message)
          |> actor.start
          |> result.map(wrap_recorder_subject)
          |> result.map_error(string.inspect)
          |> result.map_error(string.append("Failed to start recorder: ", _))
        }
      }
    }
  }
}

fn wrap_recorder_subject(
  started: actor.Started(process.Subject(RecorderMessage)),
) -> Recorder {
  Recorder(subject: started.data)
}

fn build_recordings_map(
  recordings: List(recording.Recording),
  key: matching.MatchKey,
  request_transformer: RequestTransformer,
) -> dict.Dict(String, List(recording.Recording)) {
  list.fold(recordings, dict.new(), fn(acc, rec) {
    let transformed = transform_recording_request(rec, request_transformer)
    let signature = key(transformed.request)
    case dict.get(acc, signature) {
      Ok(existing) -> dict.insert(acc, signature, [transformed, ..existing])
      Error(_) -> dict.insert(acc, signature, [transformed])
    }
  })
}

fn transform_recording_request(
  rec: recording.Recording,
  request_transformer: RequestTransformer,
) -> recording.Recording {
  let recording.Recording(request, response) = rec
  let request2 = request_transformer(request)
  recording.Recording(request: request2, response: response)
}

fn transform_recording_for_persistence(
  rec: recording.Recording,
  request_transformer: RequestTransformer,
  response_transformer: ResponseTransformer,
) -> recording.Recording {
  let recording.Recording(request, response) = rec
  let request2 = request_transformer(request)
  let response2 = response_transformer(request2, response)
  recording.Recording(request: request2, response: response2)
}

fn parse_mode(mode: String) -> Result(RecorderMode, String) {
  case mode {
    "record" -> Ok(Record)
    "playback" -> Ok(Playback)
    "passthrough" -> Ok(Passthrough)
    _ ->
      Error(
        "Unknown recorder mode: "
        <> mode
        <> ". Expected one of: record, playback, passthrough",
      )
  }
}

fn resolve_directory(
  mode: Result(RecorderMode, String),
  directory: option.Option(String),
) -> Result(String, String) {
  case mode {
    Error(e) -> Error(e)
    Ok(Record) | Ok(Playback) -> {
      case directory {
        option.Some(dir) -> Ok(dir)
        option.None ->
          Error("Recorder directory is required for record/playback")
      }
    }
    Ok(Passthrough) -> Ok("")
  }
}

fn handle_recorder_message(
  state: RecorderState,
  message: RecorderMessage,
) -> Next(RecorderState, RecorderMessage) {
  case message {
    AddRecording(rec) -> {
      case state.mode {
        Record -> {
          let transformed =
            transform_recording_for_persistence(
              rec,
              state.request_transformer,
              state.response_transformer,
            )
          let key = state.key(transformed.request)

          let should_save = case dict.get(state.recordings, key) {
            Error(_) -> True
            Ok(existing) -> {
              let duplicate =
                existing
                |> list.any(fn(rec) {
                  let recording.Recording(_, response) = rec
                  responses_equal(response, transformed.response)
                })
              case duplicate {
                True -> False
                False -> True
              }
            }
          }

          let new_recordings = case should_save {
            True -> {
              case dict.get(state.recordings, key) {
                Ok(existing) ->
                  dict.insert(state.recordings, key, [transformed, ..existing])
                Error(_) -> dict.insert(state.recordings, key, [transformed])
              }
            }
            False -> state.recordings
          }

          let new_state =
            RecorderState(
              mode: state.mode,
              directory: state.directory,
              key: state.key,
              request_transformer: state.request_transformer,
              response_transformer: state.response_transformer,
              recordings: new_recordings,
            )

          case should_save {
            False -> actor.continue(new_state)
            True ->
              // Save immediately if in Record mode
              case
                storage.save_recording_immediately(
                  state.directory,
                  transformed,
                  key,
                )
              {
                Ok(_) -> actor.continue(new_state)
                Error(save_error) -> {
                  // Log error but don't crash - keep in-memory recording
                  io.println_error("Failed to save recording: " <> save_error)
                  actor.continue(new_state)
                }
              }
          }
        }
        _ -> actor.continue(state)
      }
    }
    FindRecording(request, reply_to) -> {
      case state.mode {
        Playback -> {
          let transformed_request = state.request_transformer(request)
          let key = state.key(transformed_request)
          case dict.get(state.recordings, key) {
            Error(_) | Ok([]) -> {
              process.send(reply_to, Ok(option.None))
              actor.continue(state)
            }
            Ok([rec]) -> {
              process.send(reply_to, Ok(option.Some(rec)))
              actor.continue(state)
            }
            Ok(records) -> {
              let count = list.length(records)
              let resolved = resolve_ambiguous_recordings(records)
              case resolved {
                Ok(option.Some(rec)) -> {
                  process.send(reply_to, Ok(option.Some(rec)))
                  actor.continue(state)
                }
                _ -> {
                  process.send(
                    reply_to,
                    Error(
                      "Ambiguous recording match for key: "
                      <> key
                      <> " ("
                      <> int.to_string(count)
                      <> " recordings)",
                    ),
                  )
                  actor.continue(state)
                }
              }
            }
          }
        }
        _ -> {
          // Not in playback mode: never return recordings
          process.send(reply_to, Ok(option.None))
          actor.continue(state)
        }
      }
    }
    GetRecordings(reply_to) -> {
      let all_recordings = flatten_recordings(dict.values(state.recordings))
      process.send(reply_to, all_recordings)
      actor.continue(state)
    }
    CheckMode(reply_to) -> {
      let is_record = case state.mode {
        Record -> True
        _ -> False
      }
      process.send(reply_to, is_record)
      actor.continue(state)
    }
    TransformResponse(request, response, reply_to) -> {
      let transformed_request = state.request_transformer(request)
      let transformed =
        state.response_transformer(transformed_request, response)
      process.send(reply_to, transformed)
      actor.continue(state)
    }
    Stop(reply_to) -> {
      // No need to save - recordings already saved immediately
      process.send(reply_to, Ok(Nil))
      actor.stop()
    }
  }
}

type RecorderMessage {
  AddRecording(recording: recording.Recording)
  FindRecording(
    request: recording.RecordedRequest,
    reply_to: process.Subject(
      Result(option.Option(recording.Recording), String),
    ),
  )
  GetRecordings(reply_to: process.Subject(List(recording.Recording)))
  CheckMode(reply_to: process.Subject(Bool))
  TransformResponse(
    request: recording.RecordedRequest,
    response: recording.RecordedResponse,
    reply_to: process.Subject(recording.RecordedResponse),
  )
  Stop(reply_to: process.Subject(Result(Nil, String)))
}

fn flatten_recordings(
  lists: List(List(recording.Recording)),
) -> List(recording.Recording) {
  // Flatten while preserving order within each list as stored (newest-first).
  list.fold(lists, [], fn(acc, recs) {
    list.fold(recs, acc, fn(acc2, r) { [r, ..acc2] })
  })
  |> list.reverse
}

fn resolve_ambiguous_recordings(
  records: List(recording.Recording),
) -> Result(option.Option(recording.Recording), Nil) {
  case records {
    [] -> Ok(option.None)
    [first, ..rest] -> {
      let recording.Recording(_, first_response) = first
      let all_equal =
        rest
        |> list.all(fn(rec) {
          let recording.Recording(_, response) = rec
          responses_equal(first_response, response)
        })
      case all_equal {
        True -> Ok(option.Some(first))
        False -> Ok(option.None)
      }
    }
  }
}

fn responses_equal(
  left: recording.RecordedResponse,
  right: recording.RecordedResponse,
) -> Bool {
  case left, right {
    recording.BlockingResponse(status_a, headers_a, body_a),
      recording.BlockingResponse(status_b, headers_b, body_b)
    ->
      status_a == status_b
      && headers_a == headers_b
      && normalize_body_for_compare(body_a)
      == normalize_body_for_compare(body_b)
    _, _ -> False
  }
}

// A body that is not text is compared as it is.
fn normalize_body_for_compare(body: BitArray) -> BitArray {
  case bit_array.to_string(body) {
    Ok(text) -> bit_array.from_string(normalize_text_for_compare(text))
    Error(Nil) -> body
  }
}

fn normalize_text_for_compare(body: String) -> String {
  case response_kind(body) {
    "auth_result" -> normalize_auth_result_body(body)
    _ -> body
  }
}

fn response_kind(body: String) -> String {
  case string.contains(body, "AuthenticationResult") {
    True -> "auth_result"
    False -> "other"
  }
}

fn normalize_auth_result_body(body: String) -> String {
  body
  |> replace_json_string_value("AccessToken", "<REDACTED_TOKEN>")
  |> replace_json_string_value("IdToken", "<REDACTED_TOKEN>")
  |> replace_json_string_value("RefreshToken", "<REDACTED_TOKEN>")
}

fn replace_json_string_value(
  body: String,
  key: String,
  replacement: String,
) -> String {
  let marker = "\"" <> key <> "\":\""
  case string.split(body, marker) {
    // `rest` is the value and the text after it, up to the next marker.
    [prefix, rest, ..] -> {
      let tail = string.split(rest, "\"") |> list.drop(1)
      prefix <> marker <> replacement <> "\"" <> string.join(tail, "\"")
    }
    _ -> body
  }
}

/// Add a recording to the recorder
///
/// Manually adds a recording to the recorder's in-memory state and saves it to disk
/// immediately if in Record mode. This function is typically called automatically
/// by the HTTP client when a request completes, but can be used directly for testing
/// or manual recording creation.
///
/// ## Parameters
///
/// - `recorder`: The recorder to add the recording to
/// - `rec`: The recording (request/response pair) to add
///
/// ## Behavior by Mode
///
/// - **Record mode**: Adds to in-memory state and saves to disk immediately
/// - **Playback mode**: No-op (recordings loaded from disk at startup)
/// - **Passthrough mode**: No-op (no recording functionality)
///
/// ## Examples
///
/// ### Add a recording by hand <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_add_recording.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, start}
/// import dream_http_client/recording
/// import gleam/http
/// import gleam/list
/// import gleam/option
/// import gleam/result
///
/// pub fn add_by_hand(mocks_directory: String) -> Result(Int, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///
///   // Manually add a recording
///   let manual_recording =
///     recording.Recording(
///       request: recording.RecordedRequest(
///         method: http.Get,
///         scheme: http.Https,
///         host: "api.example.com",
///         port: option.None,
///         path: "/users",
///         query: option.None,
///         headers: [],
///         body: <<>>,
///       ),
///       response: recording.BlockingResponse(status: 200, headers: [], body: <<
///         "[]",
///       >>),
///     )
///   recorder.add_recording(rec, manual_recording)
///   list.length(recorder.get_recordings(rec))
/// }
/// ```
///
/// ## Notes
///
/// - Recordings are saved immediately in Record mode (no need to call `stop()`)
/// - If save fails, error is logged but recording remains in memory
/// - If multiple recordings share the same match key, they are all stored
///   (playback lookup will error if that makes the key ambiguous)
pub fn add_recording(recorder: Recorder, rec: recording.Recording) -> Nil {
  let Recorder(subject) = recorder
  process.send(subject, AddRecording(rec))
}

/// Check if recorder is in Record mode
///
/// Determines whether the recorder is configured to capture and save real HTTP
/// requests/responses. Useful for conditional logic that only applies during recording.
///
/// ## Parameters
///
/// - `recorder`: The recorder to check
///
/// ## Returns
///
/// - `True`: Recorder is in Record mode
/// - `False`: Recorder is in Playback or Passthrough mode
///
/// ## Examples
///
/// ### Check the mode <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_is_record_mode.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/result
///
/// pub fn recording_mode_active(mocks_directory: String) -> Result(Bool, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///   recorder.is_record_mode(rec)
/// }
/// ```
///
/// ## Notes
///
/// - Returns `False` if the recorder process doesn't respond (safe default)
/// - Timeout is 1 second - recorder should respond quickly
pub fn is_record_mode(recorder: Recorder) -> Bool {
  let Recorder(subject) = recorder
  let reply_subject = process.new_subject()
  process.send(subject, CheckMode(reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(is_record) -> is_record
    Error(timeout_error) -> {
      // Process timeout (1 second) - recorder is not responding. Log the
      // timeout and return False as a safe default.
      io.println_error(
        "Recorder did not respond to CheckMode within 1 second: "
        <> string.inspect(timeout_error),
      )
      False
    }
  }
}

/// Apply the recorder's response transformer to a response.
///
/// ## Example
///
/// ### Scrub a response <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_transform_response.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, response_transformer, start}
/// import dream_http_client/recording
/// import gleam/result
///
/// fn drop_body(
///   _request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> recording.RecordedResponse {
///   case response {
///     recording.BlockingResponse(status, headers, _body) ->
///       recording.BlockingResponse(status: status, headers: headers, body: <<>>)
///     recording.StreamingResponse(..) -> response
///   }
/// }
///
/// pub fn scrubbed(
///   mocks_directory: String,
///   request: recording.RecordedRequest,
///   response: recording.RecordedResponse,
/// ) -> Result(recording.RecordedResponse, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> response_transformer(drop_body)
///     |> start(),
///   )
///   recorder.transform_response(rec, request, response)
/// }
/// ```
pub fn transform_response(
  recorder: Recorder,
  request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  let Recorder(subject) = recorder
  let reply_subject = process.new_subject()
  process.send(subject, TransformResponse(request, response, reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(transformed) -> transformed
    Error(timeout_error) -> {
      io.println_error(
        "Recorder did not respond to TransformResponse within 1 second: "
        <> string.inspect(timeout_error),
      )
      response
    }
  }
}

/// Find a matching recording for a request
///
/// Searches for a recording that matches the given request based on the recorder's
/// configured match key and request transformer. This is used internally by the HTTP client
/// during playback, but can be called directly to check if a recording exists.
///
/// ## Parameters
///
/// - `recorder`: The recorder to search in
/// - `request`: The request to find a matching recording for
///
/// ## Returns
///
/// - `Ok(Some(Recording))`: Matching recording found (unambiguous)
/// - `Ok(None)`: No matching recording found (or not in Playback mode)
/// - `Error(String)`: Playback lookup was ambiguous (multiple recordings share the same key)
///
/// ## Examples
///
/// ### Find a recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_find_recording.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, start}
/// import dream_http_client/recording
/// import gleam/http
/// import gleam/option
/// import gleam/result
///
/// pub fn look_up_text(mocks_directory: String) -> Result(String, String) {
///   use rec <- result.map(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("playback")
///     |> start(),
///   )
///
///   let request =
///     recording.RecordedRequest(
///       method: http.Get,
///       scheme: http.Http,
///       host: "localhost",
///       port: option.Some(9876),
///       path: "/text",
///       query: option.None,
///       headers: [],
///       body: <<>>,
///     )
///
///   case recorder.find_recording(rec, request) {
///     Ok(option.Some(_recording)) -> "Found recording"
///     Ok(option.None) -> "No recording found"
///     Error(reason) -> "Ambiguous match: " <> reason
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Only works in Playback mode (returns `None` in other modes)
/// - Matching uses the recorder's configured key + request transformer
/// - Returns `None` if recorder doesn't respond (safe default)
/// - Timeout is 1 second - recorder should respond quickly
pub fn find_recording(
  recorder: Recorder,
  request: recording.RecordedRequest,
) -> Result(option.Option(recording.Recording), String) {
  let Recorder(subject) = recorder
  let reply_subject = process.new_subject()
  process.send(subject, FindRecording(request, reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(result) -> result
    Error(timeout_error) -> {
      // Process timeout (1 second) - recorder is not responding. Log the
      // timeout and return None as a safe default.
      io.println_error(
        "Recorder did not respond to FindRecording within 1 second: "
        <> string.inspect(timeout_error),
      )
      Ok(option.None)
    }
  }
}

/// Get all recordings from the recorder
///
/// Retrieves all recordings currently stored in the recorder's in-memory state.
/// In Playback mode, this returns all recordings loaded from disk at startup.
/// In Record mode, this returns all recordings captured so far (including unsaved ones).
///
/// ## Parameters
///
/// - `recorder`: The recorder to get recordings from
///
/// ## Returns
///
/// - `List(Recording)`: All recordings in the recorder (empty list if none or error)
///
/// ## Examples
///
/// ### Read the captured recordings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_get_recordings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/client
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/http
/// import gleam/int
/// import gleam/list
/// import gleam/result
/// import gleam/string
///
/// pub fn count_captured(mocks_directory: String) -> Result(String, String) {
///   use rec <- result.try(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///
///   use _response <- result.map(
///     client.new()
///     |> client.scheme(http.Http)
///     |> client.host("localhost")
///     |> client.port(9876)
///     |> client.path("/text")
///     |> client.recorder(rec)
///     |> client.send()
///     |> result.map_error(string.inspect),
///   )
///
///   let recordings = recorder.get_recordings(rec)
///   "Captured " <> int.to_string(list.length(recordings)) <> " recordings"
/// }
/// ```
///
/// ## Notes
///
/// - Returns empty list if recorder doesn't respond (safe default)
/// - In Record mode, includes recordings that may not yet be saved to disk
/// - Timeout is 1 second - recorder should respond quickly
pub fn get_recordings(recorder: Recorder) -> List(recording.Recording) {
  let Recorder(subject) = recorder
  let reply_subject = process.new_subject()
  process.send(subject, GetRecordings(reply_subject))

  case process.receive(reply_subject, 1000) {
    Ok(recordings) -> recordings
    Error(timeout_error) -> {
      // Process timeout (1 second) - recorder is not responding. Log the
      // timeout and return an empty list as a safe default.
      io.println_error(
        "Recorder did not respond to GetRecordings within 1 second: "
        <> string.inspect(timeout_error),
      )
      []
    }
  }
}

/// Stop the recorder and cleanup
///
/// Stops the recorder's OTP actor process and releases resources. In Record mode,
/// recordings are already saved to disk immediately when captured, so this function
/// only performs cleanup. Calling `stop()` is optional but recommended for proper
/// resource management.
///
/// ## Parameters
///
/// - `recorder`: The recorder to stop
///
/// ## Returns
///
/// - `Ok(Nil)`: Successfully stopped the recorder
/// - `Error(String)`: Error message if the recorder doesn't respond within 5 seconds
///
/// ## Examples
///
/// ### Stop a recorder <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_recorder_stop.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/recorder.{directory, mode, start}
/// import gleam/result
///
/// pub fn start_and_stop(mocks_directory: String) -> Result(String, String) {
///   use rec <- result.try(
///     recorder.new()
///     |> directory(mocks_directory)
///     |> mode("record")
///     |> start(),
///   )
///
///   // Cleanup (optional: the recordings are already saved)
///   case recorder.stop(rec) {
///     Ok(_) -> Ok("Recorder stopped")
///     Error(reason) -> Error("Failed to stop: " <> reason)
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Recordings are saved immediately when captured - `stop()` is not required for persistence
/// - This function is optional but recommended for proper resource cleanup
/// - Timeout is 5 seconds - recorder should stop quickly
/// - After calling `stop()`, the recorder handle is no longer valid
pub fn stop(recorder: Recorder) -> Result(Nil, String) {
  let Recorder(subject) = recorder
  let reply_subject = process.new_subject()
  process.send(subject, Stop(reply_subject))

  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(timeout_error) -> {
      // Process timeout (5 seconds) - recorder is not responding. Include the
      // timeout error details in the message.
      Error(
        "Recorder did not respond within 5 seconds: "
        <> string.inspect(timeout_error),
      )
    }
  }
}
