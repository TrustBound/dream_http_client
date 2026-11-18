import dream_http_client/client
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/result

pub fn forward_chunks(
  reply_to: Subject(String),
) -> Result(client.StreamHandle, String) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/stream/fast")
  |> client.on_stream_chunk(fn(data) {
    let text = bit_array.to_string(data) |> result.unwrap("<binary>")
    process.send(reply_to, text)
  })
  |> client.start_stream()
}
