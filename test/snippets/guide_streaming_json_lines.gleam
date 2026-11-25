//// Guide: Streaming a response, step 2
////
//// Reads a stream of JSON lines. A line can arrive in two chunks, so the
//// bytes after the last newline wait in a buffer for the next chunk.

import dream_http_client/client.{
  type ClientRequest, type StreamFailure, host, path, port, scheme,
  stream_yielder,
}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/http
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/yielder

pub type FeedError {
  StreamFailed(failure: StreamFailure)
  BadLine(line: BitArray)
}

pub fn print_mock_events() -> Result(Int, FeedError) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/json")
  |> print_events()
}

/// Prints the `message` of each JSON line and returns how many it printed.
pub fn print_events(request: ClientRequest) -> Result(Int, FeedError) {
  use #(count, rest) <- result.try(
    stream_yielder(request)
    |> yielder.try_fold(#(0, <<>>), handle_chunk),
  )
  // The last line of a stream can come without a newline
  case rest {
    <<>> -> Ok(count)
    last_line -> print_lines([last_line], count)
  }
}

fn handle_chunk(
  state: #(Int, BitArray),
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(#(Int, BitArray), FeedError) {
  let #(count, pending) = state
  use chunk <- result.try(result.map_error(chunk_result, StreamFailed))
  let buffer = bit_array.append(pending, bytes_tree.to_bit_array(chunk))
  let #(lines, rest) = complete_lines(buffer)
  use new_count <- result.map(print_lines(lines, count))
  #(new_count, rest)
}

fn print_lines(lines: List(BitArray), count: Int) -> Result(Int, FeedError) {
  list.try_fold(lines, count, print_line)
}

fn print_line(count: Int, line: BitArray) -> Result(Int, FeedError) {
  use message <- result.map(
    json.parse_bits(line, message_decoder())
    |> result.replace_error(BadLine(line)),
  )
  io.println(message)
  count + 1
}

fn message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

/// Splits the complete lines off the front of `buffer`. Returns the lines
/// without their newlines, and the bytes after the last newline.
pub fn complete_lines(buffer: BitArray) -> #(List(BitArray), BitArray) {
  collect_lines(buffer, 0, [])
}

fn collect_lines(
  buffer: BitArray,
  index: Int,
  lines: List(BitArray),
) -> #(List(BitArray), BitArray) {
  case buffer {
    <<line:bytes-size(index), "\n", rest:bytes>> ->
      collect_lines(rest, 0, [line, ..lines])
    <<_:bytes-size(index), _, _:bytes>> ->
      collect_lines(buffer, index + 1, lines)
    _ -> #(list.reverse(lines), buffer)
  }
}
