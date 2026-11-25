import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub fn count_captured(mocks_directory: String) -> Result(String, String) {
  use rec <- result.try(
    recorder.new()
    |> directory(mocks_directory)
    |> mode(recorder.Record)
    |> start(),
  )

  use _response <- result.map(
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/text")
    |> client.recorder(rec)
    |> client.send()
    |> result.map_error(string.inspect),
  )

  let recordings = recorder.get_recordings(rec)
  "Captured " <> int.to_string(list.length(recordings)) <> " recordings"
}
