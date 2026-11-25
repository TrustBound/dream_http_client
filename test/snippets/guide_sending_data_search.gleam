//// Guide: Sending data to an API, step 3
////
//// Builds a query string from pairs, so each value is encoded.

import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, path, query, send,
}
import gleam/int
import gleam/uri

pub fn search_todos(
  api: ClientRequest,
  words: String,
  page: Int,
) -> Result(HttpResponse, SendError) {
  let query_string =
    uri.query_to_string([#("q", words), #("page", int.to_string(page))])

  api
  |> path("/get")
  |> query(query_string)
  |> send()
}
