//// Guide: Handling errors, timeouts and retries, step 3
////
//// Reads where a redirect points, instead of following it.

import dream_http_client/client.{type ClientRequest, auto_redirect, path, send}
import gleam/list
import gleam/result

pub fn redirect_target(
  api: ClientRequest,
  from: String,
) -> Result(String, Nil) {
  use response <- result.try(
    api
    |> path(from)
    |> auto_redirect(False)
    |> send()
    |> result.replace_error(Nil),
  )
  list.find(response.headers, fn(header) { header.name == "location" })
  |> result.map(fn(header) { header.value })
}
