//// Guide: Streaming into an OTP actor, steps 1 to 4
////
//// An actor that downloads a stream, keeps its progress, answers questions
//// about it while the stream runs, and can cancel it.

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

/// Asks the tracker for its progress. The actor answers between two stream
/// messages, so the answer comes at once while the stream runs.
pub fn progress(tracker: Subject(Message)) -> Progress {
  actor.call(tracker, 1000, GetProgress)
}

/// Stops the stream. No message of the stream reaches the actor after this.
pub fn cancel(tracker: Subject(Message)) -> Nil {
  process.send(tracker, Cancel)
}
