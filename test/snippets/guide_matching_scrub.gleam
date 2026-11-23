//// Guide: Matching requests and hiding secrets in recordings, steps 3
//// and 4
////
//// A recorder that removes the token from each request and the cookie
//// from each response before it saves them.

import dream_http_client/recorder.{
  type Recorder, directory, mode, request_transformer, response_transformer,
  start,
}
import dream_http_client/recording.{
  type RecordedRequest, type RecordedResponse, BlockingResponse, RecordedRequest,
  StreamingResponse,
}
import gleam/list
import gleam/string

pub fn start_scrubbing_recorder(
  mode_name: String,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(mode_name)
  |> request_transformer(drop_authorization)
  |> response_transformer(drop_cookies)
  |> start()
}

/// Runs before the recorder computes the key and before it saves, in
/// every mode, so a request with another token still matches.
pub fn drop_authorization(request: RecordedRequest) -> RecordedRequest {
  RecordedRequest(
    ..request,
    headers: list.filter(request.headers, fn(header) {
      string.lowercase(header.0) != "authorization"
    }),
  )
}

/// Runs only in record mode, before the recorder saves the response.
pub fn drop_cookies(
  _request: RecordedRequest,
  response: RecordedResponse,
) -> RecordedResponse {
  case response {
    BlockingResponse(status: status, headers: headers, body: body) ->
      BlockingResponse(
        status: status,
        headers: without_cookies(headers),
        body: body,
      )
    StreamingResponse(status: status, headers: headers, chunks: chunks) ->
      StreamingResponse(
        status: status,
        headers: without_cookies(headers),
        chunks: chunks,
      )
  }
}

fn without_cookies(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) { string.lowercase(header.0) != "set-cookie" })
}
