//// Guide: Streaming a response, step 5
////
//// Takes the first chunk of a stream, then stops the stream.

import dream_http_client/client.{
  type ClientRequest, cancel_stream_handle, on_stream_chunk, start_stream,
}
import gleam/erlang/process
import gleam/result

pub fn first_chunk(request: ClientRequest) -> Result(BitArray, String) {
  let chunks = process.new_subject()
  use handle <- result.try(
    request
    |> on_stream_chunk(fn(chunk) { process.send(chunks, chunk) })
    |> start_stream(),
  )
  let first = process.receive(chunks, 5000)
  // Stop the stream in both cases: a chunk came, or none came in time
  cancel_stream_handle(handle)
  result.replace_error(first, "No chunk arrived within 5 seconds")
}
