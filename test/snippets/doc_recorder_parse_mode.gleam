import dream_http_client/recorder.{
  type Recorder, directory, mode, parse_mode, start,
}
import gleam/result

pub fn start_from_text(
  mode_text: String,
  mocks_directory: String,
) -> Result(Recorder, String) {
  use recorder_mode <- result.try(parse_mode(mode_text))
  recorder.new()
  |> directory(mocks_directory)
  |> mode(recorder_mode)
  |> start()
}
