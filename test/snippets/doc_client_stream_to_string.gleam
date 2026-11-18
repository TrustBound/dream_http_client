import dream_http_client/client.{host, path, port, scheme, stream_yielder}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder

pub fn stream_to_string() -> Result(String, String) {
  // The stream ends by itself: no need for take()
  let chunks =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
    |> stream_yielder()
    |> yielder.to_list()

  case list.try_map(chunks, fn(chunk) { chunk }) {
    Ok(chunk_list) ->
      chunk_list
      |> list.map(bytes_tree.to_bit_array)
      |> list.map(fn(data) { bit_array.to_string(data) |> result.unwrap("") })
      |> string.join("")
      |> Ok
    Error(failure) -> Error(client.stream_failure_to_string(failure))
  }
}
