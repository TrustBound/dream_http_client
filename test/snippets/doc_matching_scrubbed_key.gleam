import dream_http_client/matching
import dream_http_client/recorder.{
  directory, key, mode, request_transformer, start,
}
import dream_http_client/recording
import gleam/list
import gleam/result

// Drop Authorization before keying and before writing to disk.
fn drop_auth(request: recording.RecordedRequest) -> recording.RecordedRequest {
  let headers =
    request.headers
    |> list.filter(fn(header) { header.0 != "Authorization" })
  recording.RecordedRequest(..request, headers: headers)
}

pub fn start_scrubbed(mocks_directory: String) -> Result(Bool, String) {
  // Build a key that ignores headers and body.
  let key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)

  use rec <- result.map(
    recorder.new()
    |> mode(recorder.Record)
    |> directory(mocks_directory)
    |> key(key_fn)
    |> request_transformer(drop_auth)
    |> start(),
  )
  recorder.is_record_mode(rec)
}
