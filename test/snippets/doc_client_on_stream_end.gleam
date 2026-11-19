import dream_http_client/client
import gleam/erlang/process.{type Subject}
import gleam/http

pub fn report_end(
  reply_to: Subject(String),
) -> Result(client.StreamHandle, String) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/stream/fast")
  |> client.on_stream_end(fn(_headers) {
    process.send(reply_to, "Stream completed")
  })
  |> client.start_stream()
}
