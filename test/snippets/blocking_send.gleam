//// README: Blocking - send()
////
//// Sends a request and turns each kind of error into a message.

import dream_http_client/client.{
  RequestError, ResponseError, host, path, port, scheme, send,
  transport_error_to_string,
}
import gleam/http
import gleam/int
import gleam/result

pub fn fetch_text() -> Result(String, String) {
  let result =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> send()

  case result {
    Ok(response) ->
      client.body_text(response)
      |> result.replace_error("The body is not text")
    Error(ResponseError(response: response)) ->
      Error("HTTP error " <> int.to_string(response.status))
    Error(RequestError(error: error)) -> Error(transport_error_to_string(error))
  }
}
