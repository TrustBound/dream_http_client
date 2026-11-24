import dream_http_client/client.{host, recorder}
import dream_http_client/recorder.{directory, mode, start}
import gleam/result

pub fn recorded_request(
  mocks_directory: String,
) -> Result(client.ClientRequest, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode(recorder.Record)
    |> start(),
  )
  client.new() |> host("api.example.com") |> recorder(rec)
}
