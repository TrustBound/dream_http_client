import dream_http_client/client
import gleam/http
import gleam/result

pub fn start_then_cancel() -> Result(Nil, String) {
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/slow")
  use stream <- result.map(client.start_stream(request))
  // Later:
  client.cancel_stream_handle(stream)
}
