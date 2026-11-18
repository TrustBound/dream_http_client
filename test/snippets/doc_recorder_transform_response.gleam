import dream_http_client/recorder.{directory, mode, response_transformer, start}
import dream_http_client/recording
import gleam/result

fn drop_body(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  case response {
    recording.BlockingResponse(status, headers, _body) ->
      recording.BlockingResponse(status: status, headers: headers, body: "")
    recording.StreamingResponse(..) -> response
  }
}

pub fn scrubbed(
  mocks_directory: String,
  request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> Result(recording.RecordedResponse, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("record")
    |> response_transformer(drop_body)
    |> start(),
  )
  recorder.transform_response(rec, request, response)
}
