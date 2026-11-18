import dream_http_client/recorder.{directory, mode, request_transformer}
import dream_http_client/recording
import gleam/list

pub fn drop_auth_header(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  let headers =
    request.headers
    |> list.filter(fn(header) { header.0 != "Authorization" })
  recording.RecordedRequest(..request, headers: headers)
}

pub fn scrubbing_builder() -> recorder.RecorderBuilder {
  recorder.new()
  |> mode("record")
  |> directory("mocks")
  |> request_transformer(drop_auth_header)
}
