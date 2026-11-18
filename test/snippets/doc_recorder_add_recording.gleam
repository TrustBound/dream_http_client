import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import gleam/http
import gleam/list
import gleam/option
import gleam/result

pub fn add_by_hand(mocks_directory: String) -> Result(Int, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("record")
    |> start(),
  )

  // Manually add a recording
  let manual_recording =
    recording.Recording(
      request: recording.RecordedRequest(
        method: http.Get,
        scheme: http.Https,
        host: "api.example.com",
        port: option.None,
        path: "/users",
        query: option.None,
        headers: [],
        body: "",
      ),
      response: recording.BlockingResponse(status: 200, headers: [], body: "[]"),
    )
  recorder.add_recording(rec, manual_recording)
  list.length(recorder.get_recordings(rec))
}
