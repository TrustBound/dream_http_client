//// Tests for stream_to() and cancel_stream(): message-based streaming to a
//// typed inbox.

import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mailbox
import fixtures/mock_server
import fixtures/recorded
import fixtures/stream_process
import fixtures/temp_directory
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/result

pub fn tests() -> TestSuite {
  describe("client.stream_to", [
    group("a normal stream", [
      it("sends StreamStart, the Chunk and StreamEnd with exact values", fn() {
        // Arrange
        use port <- edge_server.with("trailers")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)

        // Act
        let messages = mailbox.take(inbox, 3, 5000)
        let rest = mailbox.drain(inbox)

        // Assert
        #(messages, rest)
        |> should
        |> be_equal(
          #(
            [
              client.StreamStart(request_id: request_id, headers: [
                client.Header("transfer-encoding", "chunked"),
                client.Header("trailer", "x-checksum"),
              ]),
              client.Chunk(request_id: request_id, data: <<"hello">>),
              client.StreamEnd(request_id: request_id, headers: [
                client.Header("x-checksum", "abc"),
              ]),
            ],
            [],
          ),
        )
        |> or_fail_with("The messages should arrive in order, exactly once")
      }),
      it("sends each chunk in order, as it arrives", fn() {
        // Arrange
        use port <- edge_server.with("chunks")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)

        // Act
        let messages = mailbox.take(inbox, 5, 5000)
        let rest = mailbox.drain(inbox)

        // Assert
        #(messages, rest)
        |> should
        |> be_equal(
          #(
            [
              client.StreamStart(request_id: request_id, headers: [
                client.Header("transfer-encoding", "chunked"),
              ]),
              client.Chunk(request_id: request_id, data: <<"one">>),
              client.Chunk(request_id: request_id, data: <<"two">>),
              client.Chunk(request_id: request_id, data: <<"three">>),
              client.StreamEnd(request_id: request_id, headers: []),
            ],
            [],
          ),
        )
        |> or_fail_with("Each chunk should arrive in order, exactly once")
      }),
    ]),
    group("an empty body", [
      it("sends StreamStart then StreamEnd", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)

        // Act
        let messages = mailbox.take(inbox, 2, 5000)
        let rest = mailbox.drain(inbox)

        // Assert
        #(messages, rest)
        |> should
        |> be_equal(
          #(
            [
              client.StreamStart(request_id: request_id, headers: [
                client.Header("content-length", "0"),
              ]),
              client.StreamEnd(request_id: request_id, headers: []),
            ],
            [],
          ),
        )
        |> or_fail_with("An empty body should send no Chunk")
      }),
    ]),
    group("a failing stream", [
      it("sends exactly one StreamError when the connection is refused", fn() {
        // Arrange
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(mock_server.closed_port("/"), inbox)

        // Act
        let first = process.receive(inbox, 20_000)
        let rest = mailbox.drain(inbox)

        // Assert
        #(first, rest)
        |> should
        |> be_equal(
          #(
            Ok(client.StreamError(
              request_id: request_id,
              error: client.TransportFailure(client.ConnectFailed(
                "Connection refused",
              )),
            )),
            [],
          ),
        )
        |> or_fail_with("A refused connection should send one StreamError")
      }),
      it("ends with exactly one StreamError when the body times out", fn() {
        // Arrange
        use port <- edge_server.with("stall_body")
        let inbox = process.new_subject()
        let request = edge_server.request(port) |> client.timeout(300)
        let assert Ok(request_id) = client.stream_to(request, inbox)

        // Act
        let messages = mailbox.take(inbox, 2, 5000)
        let rest = mailbox.drain(inbox)

        // Assert
        #(messages, rest)
        |> should
        |> be_equal(
          #(
            [
              client.StreamStart(request_id: request_id, headers: [
                client.Header("content-length", "10"),
              ]),
              client.StreamError(
                request_id: request_id,
                error: client.TransportFailure(client.TimedOut(300)),
              ),
            ],
            [],
          ),
        )
        |> or_fail_with("A stalled body should end with one TimedOut error")
      }),
      it("ends with exactly one StreamError when the stream drops", fn() {
        // Arrange
        let request = mock_server.get("/stream/drop")

        // Act
        let endings = stream_to_endings(request)

        // Assert
        endings
        |> should
        |> be_equal(["StreamError: Remote closed connection"])
        |> or_fail_with("A dropped stream should end with one StreamError")
      }),
      it("ends with exactly one StreamError on a 500 response", fn() {
        // Arrange
        let request = mock_server.get("/stream/error")

        // Act
        let endings = stream_to_endings(request)

        // Assert
        endings
        |> should
        |> be_equal([
          "StreamError: HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
        ])
        |> or_fail_with("A 500 response should end with one StreamError")
      }),
    ]),
    group("client.cancel_stream", [
      it("stops further messages", fn() {
        // Arrange
        // The server sends the headers, then no body. Without the cancel,
        // the stream would send a TimedOut StreamError after 1 second.
        use port <- edge_server.with("stall_body")
        let inbox = process.new_subject()
        let request = edge_server.request(port) |> client.timeout(1000)
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let assert Ok(client.StreamStart(..)) = process.receive(inbox, 5000)

        // Act
        client.cancel_stream(request_id)
        let after_cancel = process.receive(inbox, 2500)

        // Assert
        after_cancel
        |> should
        |> be_equal(Error(Nil))
        |> or_fail_with("No message should arrive after the cancel")
      }),
      it("ends the stream process before it returns", fn() {
        // Arrange
        use port <- edge_server.with("stall_body")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)
        let stream_pid = stream_process.of(request_id)

        // Act
        client.cancel_stream(request_id)

        // Assert
        process.is_alive(stream_pid)
        |> should
        |> be_equal(False)
        |> or_fail_with("The stream process should have stopped")
      }),
      it("returns Nil for a stream that has ended", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)
        let stream_monitor = process.monitor(stream_process.of(request_id))
        let assert Ok(Nil) =
          process.new_selector()
          |> process.select_specific_monitor(stream_monitor, fn(_down) { Nil })
          |> process.selector_receive(5000)

        // Act
        let value = client.cancel_stream(request_id)

        // Assert
        value
        |> should
        |> be_equal(Nil)
        |> or_fail_with("A cancel of an ended stream should return Nil")
      }),
      it("returns Nil when it cancels the same stream twice", fn() {
        // Arrange
        use port <- edge_server.with("stall_body")
        let inbox = process.new_subject()
        let assert Ok(request_id) =
          client.stream_to(edge_server.request(port), inbox)

        // Act
        let first = client.cancel_stream(request_id)
        let second = client.cancel_stream(request_id)

        // Assert
        #(first, second)
        |> should
        |> be_equal(#(Nil, Nil))
        |> or_fail_with("Both cancels should return Nil")
      }),
    ]),
    group("the owner process", [
      it("stops the stream when it stops", fn() {
        // Arrange
        // The server sends the headers, then no body. A stream that kept
        // running would send a TimedOut StreamError after 1 second.
        use port <- edge_server.with("stall_body")
        let inbox = process.new_subject()
        let request_ids = process.new_subject()
        let request = edge_server.request(port) |> client.timeout(1000)
        let owner =
          process.spawn_unlinked(fn() {
            let assert Ok(request_id) = client.stream_to(request, inbox)
            process.send(request_ids, request_id)
            process.sleep_forever()
          })
        let assert Ok(request_id) = process.receive(request_ids, 5000)
        let assert Ok(client.StreamStart(..)) = process.receive(inbox, 5000)
        let stream_monitor = process.monitor(stream_process.of(request_id))

        // Act
        process.kill(owner)
        let stream_exit =
          process.new_selector()
          |> process.select_specific_monitor(stream_monitor, fn(down) {
            down.reason
          })
          |> process.selector_receive(5000)
        let after_exit = process.receive(inbox, 2500)

        // Assert
        #(stream_exit, after_exit)
        |> should
        |> be_equal(#(Ok(process.Normal), Error(Nil)))
        |> or_fail_with("The stream should stop and send nothing more")
      }),
    ]),
    group("two concurrent streams", [
      it("keep their own request_id on each message", fn() {
        // Arrange
        use chunks_port <- edge_server.with("chunks")
        use trailers_port <- edge_server.with("trailers")
        let inbox = process.new_subject()
        let assert Ok(chunks_id) =
          client.stream_to(edge_server.request(chunks_port), inbox)
        let assert Ok(trailers_id) =
          client.stream_to(edge_server.request(trailers_port), inbox)

        // Act
        let messages = mailbox.take(inbox, 8, 5000)
        let chunks_body =
          list.filter_map(messages, fn(message) {
            case message {
              client.Chunk(request_id: request_id, data: data)
                if request_id == chunks_id
              -> Ok(data)
              _ -> Error(Nil)
            }
          })
          |> bit_array.concat
        let trailers_body =
          list.filter_map(messages, fn(message) {
            case message {
              client.Chunk(request_id: request_id, data: data)
                if request_id == trailers_id
              -> Ok(data)
              _ -> Error(Nil)
            }
          })
          |> bit_array.concat

        // Assert
        #(chunks_body, trailers_body)
        |> should
        |> be_equal(#(<<"onetwothree">>, <<"hello">>))
        |> or_fail_with("Each stream should get only its own chunks")
      }),
    ]),
    group("with a recorder", [
      it("saves the stream in record mode", fn() {
        // Arrange
        let path = temp_directory.path("stream_to_records")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode(recorder.Record) |> start()
        use port <- edge_server.with("chunks")
        let inbox = process.new_subject()
        let request = edge_server.request(port) |> client.recorder(rec)
        let assert Ok(_request_id) = client.stream_to(request, inbox)

        // Act
        let _messages = mailbox.take(inbox, 5, 5000)
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.StreamingResponse(status, _headers, recorded_chunks) -> #(
                  status,
                  list.map(recorded_chunks, fn(chunk) { chunk.data })
                    |> bit_array.concat,
                )
                recording.BlockingResponse(status, _headers, _body) -> #(
                  status,
                  <<>>,
                )
              }
            }),
          )

        // Assert
        value
        |> should
        |> be_equal(Ok([#(200, <<"onetwothree">>)]))
        |> or_fail_with("The whole stream should be saved")
      }),
      it("sends the recorded stream in playback mode", fn() {
        // Arrange
        let path = temp_directory.path("stream_to_playback")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.StreamingResponse(
                status: 200,
                headers: [#("content-type", "text/plain")],
                chunks: [
                  recording.Chunk(data: <<"one ">>, delay_ms: 0),
                  recording.Chunk(data: <<"two">>, delay_ms: 5),
                ],
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new()
          |> directory(path)
          |> mode(recorder.Playback)
          |> start()
        let inbox = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)
        let assert Ok(request_id) = client.stream_to(request, inbox)

        // Act
        let messages = mailbox.take(inbox, 4, 5000)
        let rest = mailbox.drain(inbox)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(messages, rest)
        |> should
        |> be_equal(
          #(
            [
              client.StreamStart(request_id: request_id, headers: [
                client.Header("content-type", "text/plain"),
              ]),
              client.Chunk(request_id: request_id, data: <<"one ">>),
              client.Chunk(request_id: request_id, data: <<"two">>),
              client.StreamEnd(request_id: request_id, headers: []),
            ],
            [],
          ),
        )
        |> or_fail_with("Playback should send the recorded stream")
      }),
    ]),
  ])
}

// Runs `request` with stream_to() until its stream process stops, and
// returns each StreamEnd and StreamError message, oldest first.
fn stream_to_endings(request: client.ClientRequest) -> List(String) {
  let inbox = process.new_subject()
  let assert Ok(request_id) = client.stream_to(request, inbox)
  let stream_monitor = process.monitor(stream_process.of(request_id))
  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(stream_monitor, fn(down) { down })
    |> process.selector_receive(20_000)
  mailbox.drain(inbox)
  |> list.filter_map(describe_ending)
}

fn describe_ending(message: client.StreamMessage) -> Result(String, Nil) {
  case message {
    client.StreamEnd(..) -> Ok("StreamEnd")
    client.StreamError(error: error, ..) ->
      Ok("StreamError: " <> client.stream_failure_to_string(error))
    client.StreamStart(..) -> Error(Nil)
    client.Chunk(..) -> Error(Nil)
  }
}
