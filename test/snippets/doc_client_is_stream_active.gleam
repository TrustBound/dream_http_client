import dream_http_client/client
import gleam/http
import gleam/result

pub fn running_after_start() -> Result(Bool, String) {
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/slow")
  use stream <- result.map(client.start_stream(request))
  let active = client.is_stream_active(stream)
  client.cancel_stream_handle(stream)
  active
}
