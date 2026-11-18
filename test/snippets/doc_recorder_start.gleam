import dream_http_client/recorder.{directory, mode, start}
import gleam/result

pub fn start_playback(mocks_directory: String) -> Result(Bool, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("playback")
    |> start(),
  )
  recorder.is_record_mode(rec)
}
