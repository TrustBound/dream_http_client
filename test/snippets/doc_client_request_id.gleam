import dream_http_client/client
import gleam/erlang/process
import gleam/http
import gleam/result

pub fn first_message_is_ours() -> Result(Bool, String) {
  let inbox = process.new_subject()
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/fast")
  use request_id <- result.try(client.stream_to(request, inbox))
  let first_message = process.receive(inbox, 5000)
  client.cancel_stream(request_id)
  case first_message {
    // Every message of the stream carries the id that stream_to returned
    Ok(message) -> Ok(message.request_id == request_id)
    Error(Nil) -> Error("No message within 5 seconds")
  }
}
