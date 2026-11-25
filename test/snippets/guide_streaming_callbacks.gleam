//// Guide: Streaming a response, step 4
////
//// Downloads a stream to a file in the background with callbacks, and waits
//// for the outcome.

import dream_http_client/client.{
  cancel_stream_handle, host, on_stream_chunk, on_stream_end, on_stream_error,
  path, port, scheme, start_stream, stream_failure_to_string,
}
import gleam/erlang/process
import gleam/http
import gleam/io
import gleam/result
import simplifile

pub fn download_to_file(file_path: String) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.write_bits(file_path, <<>>)
    |> result.map_error(simplifile.describe_error),
  )
  let finished = process.new_subject()
  use handle <- result.try(
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
    // These callbacks run in the stream process, not in this one
    |> on_stream_chunk(fn(chunk) { append_chunk(file_path, chunk) })
    |> on_stream_end(fn(_trailers) { process.send(finished, Ok(Nil)) })
    |> on_stream_error(fn(failure) {
      process.send(finished, Error(stream_failure_to_string(failure)))
    })
    |> start_stream(),
  )
  // This process is free until it waits here
  case process.receive(finished, 60_000) {
    Ok(outcome) -> outcome
    Error(Nil) -> {
      cancel_stream_handle(handle)
      Error("The download did not finish within 60 seconds")
    }
  }
}

fn append_chunk(file_path: String, chunk: BitArray) -> Nil {
  case simplifile.append_bits(file_path, chunk) {
    Ok(Nil) -> Nil
    Error(error) ->
      io.println_error(
        "Cannot write " <> file_path <> ": " <> simplifile.describe_error(error),
      )
  }
}
