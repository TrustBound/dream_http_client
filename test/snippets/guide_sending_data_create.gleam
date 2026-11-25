//// Guide: Sending data to an API, step 1
////
//// Sends a JSON body with POST.

import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, add_header, body,
  method, path, send,
}
import gleam/http
import gleam/json

pub fn create_todo(
  api: ClientRequest,
  title: String,
) -> Result(HttpResponse, SendError) {
  let todo_json =
    json.object([#("title", json.string(title)), #("done", json.bool(False))])

  api
  |> method(http.Post)
  |> path("/post")
  |> add_header("content-type", "application/json")
  |> body(json.to_string(todo_json))
  |> send()
}
