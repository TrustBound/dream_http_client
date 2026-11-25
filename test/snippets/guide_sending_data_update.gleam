//// Guide: Sending data to an API, step 2
////
//// Sends PUT, PATCH and DELETE requests through one helper.

import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, add_header, body,
  method, path, send,
}
import gleam/http
import gleam/json

pub fn replace_todo(
  api: ClientRequest,
  title: String,
) -> Result(HttpResponse, SendError) {
  let todo_json =
    json.object([#("title", json.string(title)), #("done", json.bool(False))])
  send_json(api, http.Put, "/put", todo_json)
}

pub fn mark_done(api: ClientRequest) -> Result(HttpResponse, SendError) {
  send_json(
    api,
    http.Patch,
    "/patch",
    json.object([#("done", json.bool(True))]),
  )
}

pub fn delete_todo(api: ClientRequest) -> Result(HttpResponse, SendError) {
  api
  |> method(http.Delete)
  |> path("/delete")
  |> send()
}

fn send_json(
  api: ClientRequest,
  verb: http.Method,
  to: String,
  payload: json.Json,
) -> Result(HttpResponse, SendError) {
  api
  |> method(verb)
  |> path(to)
  |> add_header("content-type", "application/json")
  |> body(json.to_string(payload))
  |> send()
}
