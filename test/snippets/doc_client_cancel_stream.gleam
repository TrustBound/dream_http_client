import dream_http_client/client
import gleam/erlang/process
import gleam/http
import gleam/result

pub fn start_then_cancel() -> Result(Nil, String) {
  let inbox = process.new_subject()
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/fast")
  use request_id <- result.map(client.stream_to(request, inbox))
  // Later: no message of this stream comes after the cancel
  client.cancel_stream(request_id)
}
