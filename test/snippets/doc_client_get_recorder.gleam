import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import gleam/option
import gleam/result

pub fn has_recorder(mocks_directory: String) -> Result(Bool, String) {
  use rec <- result.map(
    recorder.new()
    |> directory(mocks_directory)
    |> mode(recorder.Record)
    |> start(),
  )
  let request = client.new() |> client.recorder(rec)
  option.is_some(client.get_recorder(request))
}
