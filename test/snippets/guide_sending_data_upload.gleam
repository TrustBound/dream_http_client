//// Guide: Sending data to an API, step 5
////
//// Sends bytes that are not text, such as a file.

import dream_http_client/client.{
  type ClientRequest, type SendError, add_header, body_bits, method, send,
}
import gleam/http
import gleam/result

pub fn upload(
  api: ClientRequest,
  bytes: BitArray,
) -> Result(BitArray, SendError) {
  api
  |> method(http.Post)
  |> add_header("content-type", "application/octet-stream")
  |> body_bits(bytes)
  |> send()
  |> result.map(fn(response) { response.body })
}
