//// Guide: Controlling connections, step 1
////
//// Sends requests at the same time, one process for each, and returns
//// their statuses in the order of the requests.

import dream_http_client/client.{type ClientRequest, type SendError, send}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result

pub fn send_all(requests: List(ClientRequest)) -> List(Result(Int, SendError)) {
  requests
  |> list.map(start_request)
  |> list.map(await_status)
}

fn start_request(request: ClientRequest) -> Subject(Result(Int, SendError)) {
  let reply_to = process.new_subject()
  process.spawn(fn() {
    let status = send(request) |> result.map(fn(response) { response.status })
    process.send(reply_to, status)
  })
  reply_to
}

fn await_status(
  reply_to: Subject(Result(Int, SendError)),
) -> Result(Int, SendError) {
  // A request ends with its own timeout, so a reply always comes
  process.receive_forever(reply_to)
}
