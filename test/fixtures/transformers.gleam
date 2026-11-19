//// Request and response transformers that tests give to the recorder.

import dream_http_client/recording
import gleam/list

/// Remove the `Authorization` header and the body of a request.
pub fn scrub_auth_and_body(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  recording.RecordedRequest(
    ..request,
    headers: list.filter(request.headers, fn(header) {
      header.0 != "Authorization"
    }),
    body: "",
  )
}

/// Remove `set-cookie` headers from a response, and the body of a blocking
/// response.
pub fn scrub_cookies_and_body(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  case response {
    recording.BlockingResponse(status, headers, _body) ->
      recording.BlockingResponse(
        status: status,
        headers: without_set_cookie(headers),
        body: "",
      )
    recording.StreamingResponse(status, headers, chunks) ->
      recording.StreamingResponse(
        status: status,
        headers: without_set_cookie(headers),
        chunks: chunks,
      )
  }
}

fn without_set_cookie(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) { header.0 != "set-cookie" })
}
