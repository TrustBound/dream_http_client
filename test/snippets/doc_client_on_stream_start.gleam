import dream_http_client/client
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/list

pub fn report_header_count(
  reply_to: Subject(Int),
) -> Result(client.StreamHandle, String) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/stream/fast")
  |> client.on_stream_start(fn(headers) {
    process.send(reply_to, list.length(headers))
  })
  |> client.start_stream()
}
