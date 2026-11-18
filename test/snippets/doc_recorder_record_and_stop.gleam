import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import gleam/http
import gleam/result
import gleam/string

pub fn record_and_stop(mocks_directory: String) -> Result(Nil, String) {
  // Record mode
  use rec <- result.try(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("record")
    |> start(),
  )

  // Use the recorder with requests
  use _response <- result.try(
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/text")
    |> client.recorder(rec)
    |> client.send()
    |> result.map_error(string.inspect),
  )

  // Cleanup (optional: the recordings are already saved)
  recorder.stop(rec)
}
