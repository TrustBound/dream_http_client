import dream_http_client/recorder.{directory, mode, start}
import gleam/result

pub fn recording_mode_active(mocks_directory: String) -> Result(Bool, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("record")
    |> start(),
  )
  recorder.is_record_mode(rec)
}
