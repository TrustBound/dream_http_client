//// Guide: Streaming a response, timeouts
////
//// Reads a 10-second stream with a 3-second timeout. The timeout limits
//// the wait for each chunk, not the whole stream.

import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder, timeout,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/result
import gleam/yielder

pub fn count_slow_chunks() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  // The server sends a chunk each 2 seconds, for 10 seconds in all
  |> path("/stream/slow")
  |> timeout(3000)
  |> stream_yielder()
  |> yielder.try_fold(0, count_chunk)
}

fn count_chunk(
  count: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use _chunk <- result.map(chunk_result)
  count + 1
}
