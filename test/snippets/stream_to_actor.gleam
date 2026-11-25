//// Message-based streaming in an OTP actor
////
//// Note: Uses localhost:9876 (dream_mock_server).

import dream_http_client/client.{
  type StreamMessage, Chunk, StreamEnd, StreamError, StreamStart, host, path,
  port, scheme, stream_failure_to_string, stream_to,
}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/otp/actor
import gleam/result

pub type State {
  State(body: BitArray, done: Subject(Result(BitArray, String)))
}

pub fn download_body() -> Result(BitArray, String) {
  let done = process.new_subject()
  use _started <- result.try(
    actor.new_with_initialiser(1000, fn(_self) { start_download(done) })
    |> actor.on_message(handle_stream_message)
    |> actor.start
    |> result.map_error(describe_start_error),
  )
  case process.receive(done, 10_000) {
    Ok(body_result) -> body_result
    Error(Nil) -> Error("The download did not end within 10 seconds")
  }
}

fn start_download(
  done: Subject(Result(BitArray, String)),
) -> Result(actor.Initialised(State, StreamMessage, Nil), String) {
  let inbox = process.new_subject()
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
  // The actor owns the stream: the stream stops when the actor stops
  use _request_id <- result.map(stream_to(request, inbox))
  let selector = process.new_selector() |> process.select(inbox)
  actor.initialised(State(body: <<>>, done: done))
  |> actor.selecting(selector)
}

fn handle_stream_message(
  state: State,
  message: StreamMessage,
) -> actor.Next(State, StreamMessage) {
  case message {
    StreamStart(..) -> actor.continue(state)
    Chunk(data: data, ..) ->
      actor.continue(State(..state, body: bit_array.append(state.body, data)))
    StreamEnd(..) -> {
      process.send(state.done, Ok(state.body))
      actor.stop()
    }
    StreamError(error: error, ..) -> {
      process.send(state.done, Error(stream_failure_to_string(error)))
      actor.stop()
    }
  }
}

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "The download actor did not start in time"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_reason) -> "The download actor stopped while it started"
  }
}
