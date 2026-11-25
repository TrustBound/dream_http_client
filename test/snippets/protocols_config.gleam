//// Demonstrates using HTTP/2 over cleartext (h2c) with protocol preference.

import dream_http_client/client.{type HttpResponse, type SendError, Http2Only}
import gleam/http

pub fn h2c_request() -> Result(HttpResponse, SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/text")
  |> client.protocols(Http2Only)
  |> client.send()
}
