//// Guide: Getting started, step 1
////
//// Sends one GET request and prints the status and the body.

import dream_http_client/client.{
  type HttpResponse, host, path, port, scheme, send,
}
import gleam/http
import gleam/int
import gleam/io
import gleam/result
import gleam/string

pub fn main() -> Nil {
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")

  case send(request) {
    Ok(response) -> print_response(response)
    Error(error) -> io.println("The request failed: " <> string.inspect(error))
  }
}

fn print_response(response: HttpResponse) -> Nil {
  let text = client.body_text(response) |> result.unwrap("<not text>")
  io.println("Status: " <> int.to_string(response.status))
  io.println("Body: " <> text)
}
