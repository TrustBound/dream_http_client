import dream_http_client/client.{host, path, port, recorder, scheme, send}
import dream_http_client/recorder.{directory, mode, start}
import gleam/http
import gleam/result
import gleam/string

pub fn record_call(mocks_directory: String) -> Result(BitArray, String) {
  use rec <- result.try(
    recorder.new()
    |> directory(mocks_directory)
    |> mode("record")
    |> start(),
  )
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> recorder(rec)
  |> send()
  |> result.map(fn(response) { response.body })
  |> result.map_error(string.inspect)
}
