import dream_http_client/matching
import dream_http_client/recorder.{
  directory, key, mode, request_transformer, response_transformer,
}
import dream_http_client/recording

pub fn drop_headers(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  recording.RecordedRequest(..request, headers: [])
}

pub fn drop_body(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  case response {
    recording.BlockingResponse(status, headers, _body) ->
      recording.BlockingResponse(status: status, headers: headers, body: <<>>)
    recording.StreamingResponse(..) -> response
  }
}

pub fn record_builder(mocks_directory: String) -> recorder.RecorderBuilder {
  recorder.new()
  |> directory(mocks_directory)
  |> mode(recorder.Record)
  |> key(matching.request_key(
    method: True,
    url: True,
    headers: False,
    body: False,
  ))
  |> request_transformer(drop_headers)
  |> response_transformer(drop_body)
}
