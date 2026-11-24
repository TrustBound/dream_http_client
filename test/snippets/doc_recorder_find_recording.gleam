import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import gleam/http
import gleam/option
import gleam/result

pub fn look_up_text(mocks_directory: String) -> Result(String, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode(recorder.Playback)
    |> start(),
  )

  let request =
    recording.RecordedRequest(
      method: http.Get,
      scheme: http.Http,
      host: "localhost",
      port: option.Some(9876),
      path: "/text",
      query: option.None,
      headers: [],
      body: <<>>,
    )

  case recorder.find_recording(rec, request) {
    Ok(option.Some(_recording)) -> "Found recording"
    Ok(option.None) -> "No recording found"
    Error(reason) -> "Ambiguous match: " <> reason
  }
}
