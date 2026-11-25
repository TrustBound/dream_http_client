//// Guide: Testing with recorded responses, step 3
////
//// Reads every chunk of a stream, live or from a recording.

import dream_http_client/client.{
  type ClientRequest, type StreamFailure, path, stream_yielder,
}
import gleam/bytes_tree
import gleam/list
import gleam/result
import gleam/yielder

pub fn fetch_chunks(
  api: ClientRequest,
) -> Result(List(BitArray), StreamFailure) {
  api
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.to_list()
  |> result.all()
  |> result.map(list.map(_, bytes_tree.to_bit_array))
}
