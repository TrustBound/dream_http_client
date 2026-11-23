# Streaming to actors

This guide shows how to send a stream to an OTP actor as typed messages with `stream_to()`. Use it for OTP actors that handle a stream as messages, next to their other messages.

## How it works

`stream_to(request, inbox)` runs the stream in its own process, like `start_stream()`, and sends typed `StreamMessage` values to `inbox`: `StreamStart`, a `Chunk` for each part of the body, then exactly one `StreamEnd` or `StreamError`. Each message carries the `RequestId` that `stream_to()` returned. Add `inbox` to the selector of your actor with `process.select`. No untyped message reaches the mailbox of the actor.

The process that calls `stream_to()` owns the stream: when it stops, the stream stops too. `cancel_stream(request_id)` stops the stream at once, and no message of the stream arrives after it returns.

## Stream into an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L5-L75"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
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
```

## When to use which

- Use `start_stream()` when the stream work can run in the stream process: callbacks such as `on_stream_chunk` run there, and a `StreamHandle` controls the stream. The stream keeps running after the process that started it stops.
- Use `stream_to()` when an actor must handle the stream in its own process, with its own state, and the stream must stop when the actor stops.

## Functions and types

- `stream_to(req, inbox) -> Result(RequestId, String)`: starts the stream, sends `StreamMessage` values to `inbox`, and returns the request ID
- `cancel_stream(request_id) -> Nil`: stops the stream. No message of the stream arrives after this returns.

**`RequestId`**: an opaque identifier of a `stream_to()` stream, carried by each of its messages

**`StreamMessage`**: a message of a `stream_to()` stream:

- `StreamStart(request_id, headers)`: the response headers arrived
- `Chunk(request_id, data)`: the next part of the body
- `StreamEnd(request_id, headers)`: the body is complete (`headers` holds the trailing headers)
- `StreamError(request_id, error: StreamFailure)`: the stream failed

## See also

- [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): stream with a yielder or with callbacks
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle each kind of error
- [Recording and playback](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record streams and play them back
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
