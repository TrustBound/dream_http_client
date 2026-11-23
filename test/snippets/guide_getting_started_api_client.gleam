//// Guide: Getting started, steps 2 and 3
////
//// A small client for one endpoint of an API: it sends the request,
//// checks the answer and decodes its JSON into a Gleam type.

import dream_http_client/client.{
  type ClientRequest, type TransportError, RequestError, ResponseError, path,
  send,
}
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/result

pub type Greeting {
  Greeting(message: String, success: Bool)
}

pub type ApiError {
  /// The request did not get an answer: no connection, a timeout, a
  /// connection that closed.
  Unreachable(error: TransportError)
  /// The server answered with a status of 400 or more.
  BadStatus(status: Int)
  /// The server answered 2xx, but the body is not the JSON we expect.
  BadBody(error: json.DecodeError)
}

/// The base request of the API: its scheme, host and port. Every endpoint
/// function starts from it, so one place says where the API lives.
pub fn local_api() -> ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
}

pub fn fetch_greeting(api: ClientRequest) -> Result(Greeting, ApiError) {
  use response <- result.try(
    api
    |> path("/json")
    |> send()
    |> result.map_error(to_api_error),
  )
  json.parse_bits(response.body, greeting_decoder())
  |> result.map_error(BadBody)
}

fn to_api_error(error: client.SendError) -> ApiError {
  case error {
    ResponseError(response: response) -> BadStatus(status: response.status)
    RequestError(error: transport_error) -> Unreachable(error: transport_error)
  }
}

fn greeting_decoder() -> decode.Decoder(Greeting) {
  use message <- decode.field("message", decode.string)
  use success <- decode.field("success", decode.bool)
  decode.success(Greeting(message: message, success: success))
}

/// A message about the error, for a log or for the person who waits.
pub fn describe_api_error(error: ApiError) -> String {
  case error {
    Unreachable(error: transport_error) ->
      "Cannot reach the API: "
      <> client.transport_error_to_string(transport_error)
    BadStatus(status: status) -> "The API answered " <> int.to_string(status)
    BadBody(error: _) -> "The API sent a body that is not a greeting"
  }
}
