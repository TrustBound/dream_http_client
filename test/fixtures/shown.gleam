//// Values written the way the guides show them, for the tests that
//// compare real output with the output files in `test/outputs/`.
//// `string.inspect` writes a UTF-8 bit array as a string and a response
//// with its changing date header, so these helpers write them in a form
//// that is the same in every run.

import dream_http_client/client.{type HttpResponse, type SendError}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A bit array as Gleam code writes it: `<<"text">>` for UTF-8 bytes,
/// `<<>>` when empty, and the bytes for any other content.
pub fn bits(data: BitArray) -> String {
  case data, bit_array.to_string(data) {
    <<>>, _ -> "<<>>"
    _, Ok(text) -> "<<" <> string.inspect(text) <> ">>"
    _, Error(Nil) -> string.inspect(data)
  }
}

/// A list of bit arrays, each one written by `bits`.
pub fn bits_list(chunks: List(BitArray)) -> String {
  "[" <> string.join(list.map(chunks, bits), ", ") <> "]"
}

/// A result of `send`: a response as `Ok(response)` with its status and its
/// body as text, and an error as it is.
pub fn sent(result: Result(HttpResponse, SendError)) -> String {
  case result {
    Ok(response) ->
      "Ok(response)  (status "
      <> int.to_string(response.status)
      <> ", body "
      <> string.inspect(client.body_text(response) |> result.unwrap(""))
      <> ")"
    Error(_) -> string.inspect(result)
  }
}
