//// Recorded requests and responses that tests use as input.

import dream_http_client/recording
import gleam/http
import gleam/option

/// A recorded `GET http://localhost:9876/text` with no headers and no body.
pub fn text_request() -> recording.RecordedRequest {
  recording.RecordedRequest(
    method: http.Get,
    scheme: http.Http,
    host: "localhost",
    port: option.Some(9876),
    path: "/text",
    query: option.None,
    headers: [],
    body: "",
  )
}

/// A blocking 200 response with no headers and `body`.
pub fn ok_response(body: String) -> recording.RecordedResponse {
  recording.BlockingResponse(status: 200, headers: [], body: body)
}

/// A recorded POST to `/text` with an `Authorization` header and a JSON
/// body that both hold `secret`. The port is not set.
pub fn secret_post_request(secret: String) -> recording.RecordedRequest {
  recording.RecordedRequest(
    ..text_request(),
    method: http.Post,
    port: option.None,
    headers: [#("Authorization", "Bearer " <> secret), #("X-Ok", "1")],
    body: "{\"secret\":\"" <> secret <> "\"}",
  )
}

/// `secret_post_request` after `transformers.scrub_auth_and_body`.
pub fn scrubbed_post_request() -> recording.RecordedRequest {
  recording.RecordedRequest(
    ..text_request(),
    method: http.Post,
    port: option.None,
    headers: [#("X-Ok", "1")],
  )
}

/// A recording of `text_request()` with a 200 `Hello, World!` response.
pub fn text_recording() -> recording.Recording {
  recording.Recording(
    request: text_request(),
    response: ok_response("Hello, World!"),
  )
}

/// A recording of a GET to `path` on localhost:9876, with an optional
/// `query` and a 200 response with `body`.
pub fn recording_at(
  path: String,
  query: option.Option(String),
  body: String,
) -> recording.Recording {
  recording.Recording(
    request: recording.RecordedRequest(
      ..text_request(),
      path: path,
      query: query,
    ),
    response: ok_response(body),
  )
}
