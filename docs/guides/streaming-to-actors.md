# Streaming into an OTP actor

Some streams belong to a long-lived process: a chat session that relays a model's answer token by token, a job runner that downloads a file while the rest of the system asks how far it got, a service that follows an event feed for hours. That process is usually an OTP actor, with its own state and its own messages. A yielder would block it, and callbacks would run in another process that can't touch its state. What you want is the stream as messages in the actor's own mailbox, next to everything else it handles. That's what `stream_to` does, and this guide builds an actor around it.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [When to use stream_to](#when-to-use-stream_to)
- [Step 1: Start a stream from the actor](#step-1-start-a-stream-from-the-actor)
- [Step 2: Handle the stream messages](#step-2-handle-the-stream-messages)
- [Step 3: Answer other messages while the stream runs](#step-3-answer-other-messages-while-the-stream-runs)
- [Step 4: Cancel the stream](#step-4-cancel-the-stream)
- [When a stream fails](#when-a-stream-fails)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll build a download tracker actor that:

- Starts a stream when it starts, and owns it.
- Counts the bytes and chunks of the stream in its own state.
- Answers "how far are you?" at any time, while the stream runs.
- Records why a stream failed: an error status or a dropped connection.
- Cancels its stream on request, with no message arriving after that.

## Before you start

You need the package, and `gleam_otp` for the actor:

```sh
gleam add dream_http_client gleam_otp
```

The examples stream from [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`. Its `/stream/fast` endpoint sends 10 chunks (`Chunk 1\n` to `Chunk 10\n`, 81 bytes in all) 100 ms apart, `/stream/slow` sends 5 chunks 2 seconds apart, `/stream/error` answers 500, and `/stream/drop` sends 2 chunks and closes the connection. The [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code) guide shows how to add and start it.

It helps to know actors in `gleam_otp`: `actor.new_with_initialiser`, `actor.on_message`, and selectors. The [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md) guide explains chunks, flow control and stream failures, which work the same way here.

## When to use stream_to

| Your situation | Use | Why |
|:---|:---|:---|
| An actor keeps state across chunks, and handles other messages while the stream runs | `stream_to` | Stream messages arrive in the actor's mailbox, typed, between its other messages. The stream stops when the actor stops. |
| A function can wait until the stream ends | `stream_yielder` | Simpler: a fold over the chunks. See [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#step-1-read-a-stream-chunk-by-chunk). |
| Each chunk goes somewhere else (a file, a socket) and needs no shared state | `start_stream` | Callbacks run in the stream's own process. The stream keeps running when the process that started it stops. |

## Step 1: Start a stream from the actor

`stream_to(request, inbox)` starts the stream and sends its messages to `inbox`, a `Subject(StreamMessage)`. The process that calls `stream_to` owns the stream: when that process stops, the stream stops too. So call it from the actor's initialiser, not from the code that starts the actor.

Here's the start of the tracker. The actor's `Message` type wraps the stream messages and adds its own:

### Start an actor that owns a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_actors_tracker.gleam#L6-L56"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type RequestId, type StreamMessage, Chunk, StreamEnd,
  StreamError, StreamStart, cancel_stream, stream_failure_to_string, stream_to,
}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// Every message the actor handles: the messages of its stream, and the
/// messages of the rest of your program.
pub type Message {
  FromStream(message: StreamMessage)
  GetProgress(reply_to: Subject(Progress))
  Cancel
}

pub type Progress {
  Progress(bytes: Int, chunks: Int, finished: Bool, failure: Option(String))
}

type State {
  State(request_id: RequestId, progress: Progress)
}

pub fn start_tracker(
  request: ClientRequest,
) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) { initialise(self, request) })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn initialise(
  self: Subject(Message),
  request: ClientRequest,
) -> Result(actor.Initialised(State, Message, Subject(Message)), String) {
  let inbox = process.new_subject()
  // The actor calls stream_to, so the actor owns the stream
  use request_id <- result.map(stream_to(request, inbox))
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_map(inbox, FromStream)
  let progress = Progress(bytes: 0, chunks: 0, finished: False, failure: None)
  actor.initialised(State(request_id: request_id, progress: progress))
  |> actor.selecting(selector)
  |> actor.returning(self)
}
```

A few things happen in `initialise`:

- `process.new_subject()` makes the inbox in the actor's process. A subject receives only in the process that made it, so it must be made here, not by the caller.
- `stream_to` returns `Ok(request_id)` at once. The request goes out in the background. A refused connection or an error status doesn't make `stream_to` fail: it arrives later as a message.
- The selector listens to two subjects: `self`, for the actor's own messages, and `inbox`, whose `StreamMessage` values `select_map` wraps in `FromStream`. Once you call `actor.selecting`, the actor receives only what the selector selects, so `self` has to be in it.

## Step 2: Handle the stream messages

A stream sends its messages in a fixed order: one `StreamStart` with the response headers, one `Chunk` for each part of the body, then exactly one `StreamEnd` or one `StreamError`. Nothing comes after the last one. Each message carries the `RequestId` that `stream_to` returned.

The tracker turns each message into a new `Progress`:

### Update the progress for each message <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_actors_tracker.gleam#L58-L97"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    FromStream(message: stream_message) ->
      actor.continue(
        State(..state, progress: update(state.progress, stream_message)),
      )
    GetProgress(reply_to: reply_to) -> {
      process.send(reply_to, state.progress)
      actor.continue(state)
    }
    Cancel -> {
      cancel_stream(state.request_id)
      let progress =
        Progress(..state.progress, finished: True, failure: Some("Cancelled"))
      actor.continue(State(..state, progress: progress))
    }
  }
}

fn update(progress: Progress, message: StreamMessage) -> Progress {
  case message {
    StreamStart(..) -> progress
    Chunk(data: data, ..) ->
      Progress(
        ..progress,
        bytes: progress.bytes + bit_array.byte_size(data),
        chunks: progress.chunks + 1,
      )
    StreamEnd(..) -> Progress(..progress, finished: True)
    StreamError(error: failure, ..) ->
      Progress(
        ..progress,
        finished: True,
        failure: Some(stream_failure_to_string(failure)),
      )
  }
}
```

When `/stream/fast` has ended, the tracker's progress is:

### The progress at the end of the stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_actors_progress_end.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Progress(bytes: 81, chunks: 10, finished: True, failure: None)
```

The state lives in the actor, and the actor handles one message at a time, so `update` needs no locks and no buffers. If the chunks were lines of JSON, this is also where you'd keep the bytes of an unfinished line, as the streaming guide's [Step 2](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#step-2-turn-chunks-into-lines) does.

## Step 3: Answer other messages while the stream runs

This is the reason to use an actor. Between two stream messages, the actor handles whatever else is in its mailbox. Here's the function the rest of your program calls:

### Ask the tracker how far it got <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_actors_tracker.gleam#L99-L103"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Asks the tracker for its progress. The actor answers between two stream
/// messages, so the answer comes at once while the stream runs.
pub fn progress(tracker: Subject(Message)) -> Progress {
  actor.call(tracker, 1000, GetProgress)
}
```

Called right after `start_tracker` on `/stream/slow`, whose first chunk takes 2 seconds, it returns at once:

### The progress right after the start <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_actors_progress_start.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Progress(bytes: 0, chunks: 0, finished: False, failure: None)
```

A web handler can show this as a progress bar, a supervisor can log it, and another actor can decide to cancel. None of them waits for the stream.

## Step 4: Cancel the stream

To stop a stream before it ends, call `cancel_stream(request_id)` from any process. It waits until the stream has stopped, so no message of that stream reaches the inbox after it returns. The tracker does it when it gets `Cancel`:

### Cancel the download <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_actors_tracker.gleam#L105-L108"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Stops the stream. No message of the stream reaches the actor after this.
pub fn cancel(tracker: Subject(Message)) -> Nil {
  process.send(tracker, Cancel)
}
```

The `Cancel` branch of `handle_message` in Step 2 calls `cancel_stream(state.request_id)` and marks the progress as finished. On `/stream/slow`, a cancel right after the start leaves this, even 2.5 seconds later, when the first chunk would have arrived:

### The progress after a cancel <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_actors_cancel.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Progress(bytes: 0, chunks: 0, finished: True, failure: Some("Cancelled"))
```

You don't need to cancel when the actor stops. The actor owns the stream, so the stream stops with it.

## When a stream fails

A failure is the last message of a stream: `StreamError(request_id, error)`, where `error` is a `StreamFailure`. The tracker keeps its text, written by `stream_failure_to_string`. Here's what it ends with for the two failing endpoints:

### The progress after a failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_actors_failures.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
/stream/error  -> Progress(bytes: 0, chunks: 0, finished: True, failure: Some("HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n"))
/stream/drop   -> Progress(bytes: 26, chunks: 2, finished: True, failure: Some("Remote closed connection"))
```

- An error status, `HttpFailure(response)`, comes with no `StreamStart` and no chunks. The response holds the whole error body.
- A dropped connection, `TransportFailure(RemoteClosed)`, comes after the chunks that arrived. The tracker keeps them, so you know it got 26 bytes before the drop.
- A refused connection is a `TransportFailure(ConnectFailed(..))`, and it too arrives as a message after `stream_to` returned `Ok`.

Match on the `StreamFailure` variants instead of keeping the text when your actor reacts differently to each, for example to retry after a drop but not after a 404.

## Test your code

The tracker has one public way in, `start_tracker(request)`, and one way to look inside, `progress(tracker)`. A test starts it against a mock server and waits until the progress says it finished. Here's a test module with a stream that ends and one that drops. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test the tracker against a mock server <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_actors_testing.gleam#L6-L77"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{host, path, port, scheme}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/option.{None, Some}
import snippets/guide_actors_tracker.{
  type Message, type Progress, Progress, progress, start_tracker,
}

pub fn tests() -> TestSuite {
  describe("tracker", [
    it("counts every chunk of a stream that ends", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_978)
      let assert Ok(tracker) = start_tracker(stream_request(19_978, "/fast"))

      // Act
      let final = await_finished(tracker, 50)
      server.stop(mock)

      // Assert
      final
      |> should
      |> be_equal(Progress(bytes: 81, chunks: 10, finished: True, failure: None))
      |> or_fail_with("Expected all ten chunks")
    }),
    it("keeps the chunks that came before a drop", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_979)
      let assert Ok(tracker) = start_tracker(stream_request(19_979, "/drop"))

      // Act
      let final = await_finished(tracker, 50)
      server.stop(mock)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 26,
        chunks: 2,
        finished: True,
        failure: Some("Remote closed connection"),
      ))
      |> or_fail_with("Expected two chunks and the failure")
    }),
  ])
}

fn stream_request(mock_port: Int, stream: String) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
  |> path("/stream" <> stream)
}

/// Asks for the progress every 100 ms until the stream is finished, at most
/// `attempts` times.
fn await_finished(tracker: Subject(Message), attempts: Int) -> Progress {
  let current = progress(tracker)
  case current.finished || attempts <= 1 {
    True -> current
    False -> {
      process.sleep(100)
      await_finished(tracker, attempts - 1)
    }
  }
}
```

`await_finished` asks every 100 ms, up to 50 times, so a stream that never ends fails the test after 5 seconds instead of hanging it. To test exact chunk boundaries, such as a JSON line split across two chunks, play back a recording instead of a server, as the streaming guide's [testing section](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#test-your-streaming-code) shows. `stream_to` plays recordings back the same way the other stream functions do.

## Common pitfalls

**Calling `stream_to` outside the actor.** *Symptom:* the stream stops as soon as the function that started the actor returns, or it keeps running after the actor is gone. *Fix:* the process that calls `stream_to` owns the stream. Call it in the actor's initialiser, as in [Step 1](#step-1-start-a-stream-from-the-actor).

**Making the inbox in another process.** *Symptom:* the actor never gets a stream message. *Fix:* make the inbox with `process.new_subject()` inside the initialiser, so it belongs to the actor's process.

**Leaving `self` out of the selector.** *Symptom:* the stream works, but calls such as `progress(tracker)` time out. *Fix:* `actor.selecting` replaces the default selector. Select `self` too, as `initialise` does.

**Waiting for a message after the last one.** *Symptom:* an actor that waits for `StreamEnd` after a `StreamError` waits forever. *Fix:* a stream ends with exactly one `StreamEnd` or one `StreamError`. Treat both as the end.

**Slow work in the message handler.** *Symptom:* `progress(tracker)` times out while the stream runs. *Fix:* the actor answers between messages, so a handler that takes seconds per chunk makes every caller wait. Keep the handler fast, and hand slow work to another process.

## Where to go next

- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): the yielder and callbacks, flow control, timeouts on long streams, and splitting chunks into lines.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): what each `TransportError` means.
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record a stream once and replay it in tests.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `stream_to`, `StreamMessage`, `RequestId` and `cancel_stream`.
