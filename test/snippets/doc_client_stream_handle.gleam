import dream_http_client/client
import gleam/http
import gleam/result

pub fn run_to_end() -> Result(Bool, String) {
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/fast")
  use stream <- result.map(client.start_stream(request))
  // Wait for completion
  client.await_stream(stream)
  // False: the stream is done
  client.is_stream_active(stream)
}
