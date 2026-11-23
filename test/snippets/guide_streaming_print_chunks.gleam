//// Guide: Streaming a response, step 1
////
//// Prints each chunk of a stream as it arrives, with its size.

import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder,
}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/int
import gleam/io
import gleam/result
import gleam/yielder

pub fn print_chunks() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.try_fold(0, print_chunk)
}

fn print_chunk(
  count: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use chunk <- result.map(chunk_result)
  let bytes = bytes_tree.to_bit_array(chunk)
  let text = bit_array.to_string(bytes) |> result.unwrap("<binary>")
  io.print(
    "[" <> int.to_string(bit_array.byte_size(bytes)) <> " bytes] " <> text,
  )
  count + 1
}
