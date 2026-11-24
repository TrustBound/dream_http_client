import dream_http_client/recorder.{directory, mode, start}
import gleam/result

pub fn start_and_stop(mocks_directory: String) -> Result(String, String) {
  use rec <- result.try(
    recorder.new()
    |> directory(mocks_directory)
    |> mode(recorder.Record)
    |> start(),
  )

  // Cleanup (optional: the recordings are already saved)
  case recorder.stop(rec) {
    Ok(_) -> Ok("Recorder stopped")
    Error(reason) -> Error("Failed to stop: " <> reason)
  }
}
