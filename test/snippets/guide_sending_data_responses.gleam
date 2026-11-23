//// Guide: Sending data to an API, step 6
////
//// Reads a header of a response, and the body of a response that refused
//// the request.

import dream_http_client/client.{
  type HttpResponse, type SendError, RequestError, ResponseError,
  transport_error_to_string,
}
import gleam/int
import gleam/list
import gleam/result

/// The value of a response header. gun gives header names in lower case,
/// so look them up in lower case.
pub fn header_value(
  response: HttpResponse,
  name: String,
) -> Result(String, Nil) {
  list.find(response.headers, fn(header) { header.name == name })
  |> result.map(fn(header) { header.value })
}

/// What went wrong, with the body of the server's answer when it refused.
pub fn explain(result: Result(HttpResponse, SendError)) -> String {
  case result {
    Ok(response) -> "Done: " <> int.to_string(response.status)
    Error(ResponseError(response: response)) ->
      "Refused with "
      <> int.to_string(response.status)
      <> ": "
      <> result.unwrap(client.body_text(response), "<not text>")
    Error(RequestError(error: error)) ->
      "No answer: " <> transport_error_to_string(error)
  }
}
