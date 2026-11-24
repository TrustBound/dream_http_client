//// Tests for a request in playback mode that no recording matches. The
//// client sends nothing to the network and returns `NoRecording`, through
//// every entry point. In record mode the request still goes to the server.
////
//// The `empty` edge server answers 200 and counts the requests it reads.

import dream_http_client/client.{
  type StreamFailure, type StreamMessage, Chunk, NoRecording, RequestError,
  StreamEnd, StreamError, StreamStart, TransportFailure,
}
import dream_http_client/recorder.{directory, mode, start}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/temp_directory
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/yielder
import simplifile

pub type Event {
  Started
  ChunkArrived
  Ended
  Failed(failure: StreamFailure)
}

pub fn tests() -> TestSuite {
  describe("a playback request that no recording matches", [
    group("playback mode", [
      it("send returns NoRecording and sends nothing", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let request = playback_request(port, "send")

        // Act
        let result =
          client.send(request) |> result.map(fn(response) { response.status })

        // Assert
        #(result, edge_server.requests_received(port))
        |> should
        |> be_equal(#(Error(RequestError(no_recording(port))), 0))
        |> or_fail_with("A playback miss must not reach the server")
      }),
      it("stream_yielder yields NoRecording once and sends nothing", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let request = playback_request(port, "yielder")

        // Act
        let items =
          client.stream_yielder(request)
          |> yielder.take(5)
          |> yielder.map(fn(item) { result.replace(item, Nil) })
          |> yielder.to_list()

        // Assert
        #(items, edge_server.requests_received(port))
        |> should
        |> be_equal(#([Error(TransportFailure(no_recording(port)))], 0))
        |> or_fail_with("A playback miss must yield one error")
      }),
      it("start_stream calls only on_stream_error and sends nothing", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let events = process.new_subject()
        let request =
          playback_request(port, "start_stream")
          |> client.on_stream_start(fn(_headers) {
            process.send(events, Started)
          })
          |> client.on_stream_chunk(fn(_data) {
            process.send(events, ChunkArrived)
          })
          |> client.on_stream_end(fn(_headers) { process.send(events, Ended) })
          |> client.on_stream_error(fn(failure) {
            process.send(events, Failed(failure))
          })

        // Act
        let started = client.start_stream(request) |> result.replace(Nil)
        let received = collect(events, [])

        // Assert
        #(started, received, edge_server.requests_received(port))
        |> should
        |> be_equal(#(
          Ok(Nil),
          [Failed(TransportFailure(no_recording(port)))],
          0,
        ))
        |> or_fail_with("A playback miss must call only on_stream_error")
      }),
      it("stream_to sends only StreamError and sends nothing", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let inbox = process.new_subject()

        // Act
        let started =
          client.stream_to(playback_request(port, "stream_to"), inbox)
          |> result.replace(Nil)
        let received = collect_messages(inbox, [])

        // Assert
        #(started, received, edge_server.requests_received(port))
        |> should
        |> be_equal(#(
          Ok(Nil),
          [Failed(TransportFailure(no_recording(port)))],
          0,
        ))
        |> or_fail_with("A playback miss must send only StreamError")
      }),
    ]),
    group("record mode", [
      it("sends a request with no recording to the server", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let assert Ok(recording) =
          recorder.new()
          |> directory(temp_directory.path("playback_miss_record"))
          |> mode(recorder.Record)
          |> start()
        let request = edge_server.request(port) |> client.recorder(recording)

        // Act
        let result =
          client.send(request) |> result.map(fn(response) { response.status })

        // Assert
        #(result, edge_server.requests_received(port))
        |> should
        |> be_equal(#(Ok(200), 1))
        |> or_fail_with("Record mode should reach the server")
      }),
    ]),
    group("messages", [
      it("transport_error_to_string names the method and the URL", fn() {
        // Act
        let message =
          client.transport_error_to_string(NoRecording(
            method: "GET",
            url: "https://api.example.com/users/42",
          ))

        // Assert
        message
        |> should
        |> be_equal("No recording matches GET https://api.example.com/users/42")
        |> or_fail_with("The message should name the request")
      }),
    ]),
  ])
}

/// A GET request to the edge server with a path and a query, and a
/// playback recorder whose directory has no recordings.
fn playback_request(port: Int, label: String) -> client.ClientRequest {
  let recordings = temp_directory.path("playback_miss_" <> label)
  let assert Ok(Nil) = simplifile.create_directory_all(recordings)
  let assert Ok(playback) =
    recorder.new()
    |> directory(recordings)
    |> mode(recorder.Playback)
    |> start()
  edge_server.request(port)
  |> client.path("/users/42")
  |> client.query("full=true")
  |> client.recorder(playback)
}

fn no_recording(port: Int) -> client.TransportError {
  NoRecording(
    method: "GET",
    url: "http://localhost:" <> int.to_string(port) <> "/users/42?full=true",
  )
}

/// The events that arrive until none arrives for 300 ms.
fn collect(
  events: process.Subject(Event),
  received: List(Event),
) -> List(Event) {
  case process.receive(events, 300) {
    Ok(event) -> collect(events, [event, ..received])
    Error(Nil) -> list.reverse(received)
  }
}

/// The stream messages that arrive until none arrives for 300 ms, as events.
fn collect_messages(
  inbox: process.Subject(StreamMessage),
  received: List(Event),
) -> List(Event) {
  case process.receive(inbox, 300) {
    Ok(message) -> collect_messages(inbox, [to_event(message), ..received])
    Error(Nil) -> list.reverse(received)
  }
}

fn to_event(message: StreamMessage) -> Event {
  case message {
    StreamStart(..) -> Started
    Chunk(..) -> ChunkArrived
    StreamEnd(..) -> Ended
    StreamError(error: failure, ..) -> Failed(failure)
  }
}
