//// Playback of a recorded stream through stream_yielder, start_stream and
//// stream_to: a recording with a status outside 2xx gives the same
//// HttpFailure as a live stream, and the recorded chunk delays come back,
//// limited by the timeout of the request.
////
//// The timing tests check the order of the events and a minimum time, with
//// a generous maximum.

import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import fixtures/recorded
import fixtures/stream_process
import fixtures/temp_directory
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("playback of a recorded stream", [
    group("a recording with status 500", [
      it("stream_yielder yields one HttpFailure, then ends", fn() {
        // Arrange
        let rec = playback_recorder("playback_500_yielder", failing_stream())

        // Act
        let items =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.take(5)
          |> yielder.to_list
          |> list.map(result.map(_, bytes_tree.to_bit_array))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([Error(expected_failure())])
        |> or_fail_with("Playback should give the HttpFailure of a live 500")
      }),
      it("start_stream calls only on_stream_error with the HttpFailure", fn() {
        // Arrange
        let rec = playback_recorder("playback_500_start", failing_stream())
        let events = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)

        // Act
        let assert Ok(_handle) =
          client.start_stream(callback_request(request, events))
        let received = take_then_drain(events, 1)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        received
        |> should
        |> be_equal([Failed(expected_failure())])
        |> or_fail_with("Playback should give only the HttpFailure of a 500")
      }),
      it("stream_to sends only StreamError with the HttpFailure", fn() {
        // Arrange
        let rec = playback_recorder("playback_500_stream_to", failing_stream())
        let inbox = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)

        // Act
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let received = take_then_drain(inbox, 1)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        received
        |> should
        |> be_equal([
          client.StreamError(request_id: request_id, error: expected_failure()),
        ])
        |> or_fail_with("Playback should send only the StreamError of a 500")
      }),
      it("stream_yielder fails on a blocking recording with status 500", fn() {
        // Arrange
        let rec = playback_recorder("playback_500_blocking", failing_blocking())

        // Act
        let items =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.take(5)
          |> yielder.to_list
          |> list.map(result.map(_, bytes_tree.to_bit_array))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([Error(expected_failure())])
        |> or_fail_with("A blocking 500 should give the same HttpFailure")
      }),
      it("stream_to fails on a blocking recording with status 500", fn() {
        // Arrange
        let rec =
          playback_recorder("playback_500_blocking_to", failing_blocking())
        let inbox = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)

        // Act
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let received = take_then_drain(inbox, 1)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        received
        |> should
        |> be_equal([
          client.StreamError(request_id: request_id, error: expected_failure()),
        ])
        |> or_fail_with("A blocking 500 should send only the StreamError")
      }),
    ]),
    group("the recorded delays", [
      it("stream_yielder waits the recorded delays", fn() {
        // Arrange
        let rec = playback_recorder("playback_delay_yielder", delayed_stream())
        let request = mock_server.get("/text") |> client.recorder(rec)
        let started = now_milliseconds()

        // Act
        let items =
          client.stream_yielder(request)
          |> yielder.to_list
          |> list.map(result.map(_, bytes_tree.to_bit_array))
        let elapsed = now_milliseconds() - started
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(items, elapsed >= 300 && elapsed < 2000)
        |> should
        |> be_equal(#([Ok(<<"a">>), Ok(<<"b">>), Ok(<<"c">>)], True))
        |> or_fail_with("The chunks should come in order after 300 ms")
      }),
      it("start_stream waits the recorded delays", fn() {
        // Arrange
        let rec = playback_recorder("playback_delay_start", delayed_stream())
        let events = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)
        let started = now_milliseconds()

        // Act
        let assert Ok(_handle) =
          client.start_stream(callback_request(request, events))
        let received = mailbox.take(events, 5, 5000)
        let elapsed = now_milliseconds() - started
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(received, elapsed >= 300 && elapsed < 2000)
        |> should
        |> be_equal(#(
          [
            Started([]),
            Received(<<"a">>),
            Received(<<"b">>),
            Received(<<"c">>),
            Ended([]),
          ],
          True,
        ))
        |> or_fail_with("The callbacks should run in order after 300 ms")
      }),
      it("stream_to waits the recorded delays", fn() {
        // Arrange
        let rec =
          playback_recorder("playback_delay_stream_to", delayed_stream())
        let inbox = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)
        let started = now_milliseconds()

        // Act
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let received = mailbox.take(inbox, 5, 5000)
        let elapsed = now_milliseconds() - started
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(received, elapsed >= 300 && elapsed < 2000)
        |> should
        |> be_equal(#(
          [
            client.StreamStart(request_id: request_id, headers: []),
            client.Chunk(request_id: request_id, data: <<"a">>),
            client.Chunk(request_id: request_id, data: <<"b">>),
            client.Chunk(request_id: request_id, data: <<"c">>),
            client.StreamEnd(request_id: request_id, headers: []),
          ],
          True,
        ))
        |> or_fail_with("The messages should come in order after 300 ms")
      }),
      it("start_stream does not add a slow handler to the delays", fn() {
        // Arrange
        let rec =
          playback_recorder(
            "playback_delay_slow_handler",
            recording.StreamingResponse(status: 200, headers: [], chunks: [
              recording.Chunk(data: <<"a">>, delay_ms: 0),
              recording.Chunk(data: <<"b">>, delay_ms: 300),
              recording.Chunk(data: <<"c">>, delay_ms: 300),
            ]),
          )
        let ended = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.on_stream_chunk(fn(_data) { process.sleep(300) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
        let started = now_milliseconds()

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let end = process.receive(ended, 5000)
        let elapsed = now_milliseconds() - started
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(end, elapsed >= 900 && elapsed < 1400)
        |> should
        |> be_equal(#(Ok(True), True))
        |> or_fail_with(
          "A chunk should come at its recorded time after a slow handler",
        )
      }),
    ]),
    group("a recorded delay longer than the timeout", [
      it("stream_yielder yields the chunk, then TimedOut", fn() {
        // Arrange
        let rec = playback_recorder("playback_timeout_yielder", slow_stream())

        // Act
        let items =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.timeout(100)
          |> client.stream_yielder
          |> yielder.take(5)
          |> yielder.to_list
          |> list.map(result.map(_, bytes_tree.to_bit_array))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([Ok(<<"a">>), Error(timed_out(100))])
        |> or_fail_with("The wait should end with the live timeout failure")
      }),
      it("start_stream calls on_stream_error with TimedOut", fn() {
        // Arrange
        let rec = playback_recorder("playback_timeout_start", slow_stream())
        let events = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.timeout(100)

        // Act
        let assert Ok(_handle) =
          client.start_stream(callback_request(request, events))
        let received = take_then_drain(events, 3)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        received
        |> should
        |> be_equal([Started([]), Received(<<"a">>), Failed(timed_out(100))])
        |> or_fail_with("The wait should end with the live timeout failure")
      }),
      it("stream_to sends StreamError with TimedOut", fn() {
        // Arrange
        let rec = playback_recorder("playback_timeout_stream_to", slow_stream())
        let inbox = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.timeout(100)

        // Act
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let received = take_then_drain(inbox, 3)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        received
        |> should
        |> be_equal([
          client.StreamStart(request_id: request_id, headers: []),
          client.Chunk(request_id: request_id, data: <<"a">>),
          client.StreamError(request_id: request_id, error: timed_out(100)),
        ])
        |> or_fail_with("The wait should end with the live timeout failure")
      }),
    ]),
    group("a stop during a recorded delay", [
      it("cancel_stream stops a stream_to playback in its wait", fn() {
        // Arrange
        let rec = playback_recorder("playback_cancel_stream_to", long_stream())
        let inbox = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)
        let assert Ok(request_id) = client.stream_to(request, inbox)
        let first = mailbox.take(inbox, 2, 5000)

        // Act
        client.cancel_stream(request_id)
        let rest = mailbox.drain(inbox)
        let alive = process.is_alive(stream_process.of(request_id))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(list.append(first, rest), alive)
        |> should
        |> be_equal(#(
          [
            client.StreamStart(request_id: request_id, headers: []),
            client.Chunk(request_id: request_id, data: <<"a">>),
          ],
          False,
        ))
        |> or_fail_with("No message and no process should outlive the cancel")
      }),
      it("cancel_stream_handle stops a start_stream playback in its wait", fn() {
        // Arrange
        let rec = playback_recorder("playback_cancel_start", long_stream())
        let events = process.new_subject()
        let request = mock_server.get("/text") |> client.recorder(rec)
        let assert Ok(handle) =
          client.start_stream(callback_request(request, events))
        let first = mailbox.take(events, 2, 5000)

        // Act
        client.cancel_stream_handle(handle)
        let rest = mailbox.drain(events)
        let active = client.is_stream_active(handle)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(list.append(first, rest), active)
        |> should
        |> be_equal(#([Started([]), Received(<<"a">>)], False))
        |> or_fail_with("No callback and no process should outlive the cancel")
      }),
      it("a stream_to playback stops in its wait when its owner stops", fn() {
        // Arrange
        let rec = playback_recorder("playback_owner_stops", long_stream())
        let request = mock_server.get("/text") |> client.recorder(rec)
        let reply = process.new_subject()
        process.spawn_unlinked(fn() { stream_then_stop(request, reply) })
        let assert Ok(stream_pid) = process.receive(reply, 5000)

        // Act
        let stream_monitor = process.monitor(stream_pid)
        let stopped =
          process.new_selector()
          |> process.select_specific_monitor(stream_monitor, fn(_down) { True })
          |> process.selector_receive(2000)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        stopped
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("The stream process should stop with its owner")
      }),
      it("a stream_yielder playback leaves no process behind", fn() {
        // Arrange
        let rec = playback_recorder("playback_yielder_stop", long_stream())
        let request = mock_server.get("/text") |> client.recorder(rec)
        let started = now_milliseconds()

        // Act
        let first =
          client.stream_yielder(request)
          |> yielder.first
          |> result.map(result.map(_, bytes_tree.to_bit_array))
        let elapsed = now_milliseconds() - started
        let owners = stream_process.kill_yielder_owner()
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(first, elapsed < 2000, owners)
        |> should
        |> be_equal(#(Ok(Ok(<<"a">>)), True, 0))
        |> or_fail_with("The first chunk should come with no wait left behind")
      }),
    ]),
  ])
}

// What the stream callbacks of start_stream() report.
type CallbackEvent {
  Started(headers: List(client.Header))
  Received(data: BitArray)
  Ended(headers: List(client.Header))
  Failed(failure: client.StreamFailure)
}

// `request` with stream callbacks that send each event to `events`.
fn callback_request(
  request: client.ClientRequest,
  events: process.Subject(CallbackEvent),
) -> client.ClientRequest {
  request
  |> client.on_stream_start(fn(headers) {
    process.send(events, Started(headers))
  })
  |> client.on_stream_chunk(fn(data) { process.send(events, Received(data)) })
  |> client.on_stream_end(fn(headers) { process.send(events, Ended(headers)) })
  |> client.on_stream_error(fn(failure) {
    process.send(events, Failed(failure))
  })
}

// The first `count` messages on `subject`, then every message that follows
// within 100 ms.
fn take_then_drain(subject: process.Subject(a), count: Int) -> List(a) {
  let first = mailbox.take(subject, count, 5000)
  list.append(first, mailbox.drain(subject))
}

// Starts a stream_to() playback, waits for its first chunk, sends the
// stream process to `reply` and stops.
fn stream_then_stop(
  request: client.ClientRequest,
  reply: process.Subject(process.Pid),
) -> Nil {
  let inbox = process.new_subject()
  let assert Ok(request_id) = client.stream_to(request, inbox)
  let assert [_start, _chunk] = mailbox.take(inbox, 2, 5000)
  process.send(reply, stream_process.of(request_id))
}

// A recorder in playback mode with one recording of `GET /text` that
// gives `response`.
fn playback_recorder(
  label: String,
  response: recording.RecordedResponse,
) -> recorder.Recorder {
  let path = temp_directory.path(label)
  let assert Ok(Nil) =
    storage.save_recording_immediately(
      path,
      recording.Recording(request: recorded.text_request(), response: response),
      "k",
    )
  let assert Ok(rec) =
    recorder.new() |> directory(path) |> mode("playback") |> start()
  rec
}

fn failing_stream() -> recording.RecordedResponse {
  recording.StreamingResponse(
    status: 500,
    headers: [#("content-type", "text/plain")],
    chunks: [
      recording.Chunk(data: <<"server ">>, delay_ms: 0),
      recording.Chunk(data: <<"error">>, delay_ms: 0),
    ],
  )
}

fn failing_blocking() -> recording.RecordedResponse {
  recording.BlockingResponse(
    status: 500,
    headers: [#("content-type", "text/plain")],
    body: <<"server error">>,
  )
}

fn expected_failure() -> client.StreamFailure {
  client.HttpFailure(
    response: client.HttpResponse(
      status: 500,
      headers: [client.Header("content-type", "text/plain")],
      body: <<"server error">>,
    ),
  )
}

// Three chunks: at once, after 150 ms and after 150 ms more.
fn delayed_stream() -> recording.RecordedResponse {
  recording.StreamingResponse(status: 200, headers: [], chunks: [
    recording.Chunk(data: <<"a">>, delay_ms: 0),
    recording.Chunk(data: <<"b">>, delay_ms: 150),
    recording.Chunk(data: <<"c">>, delay_ms: 150),
  ])
}

// A chunk at once, then a chunk after 500 ms.
fn slow_stream() -> recording.RecordedResponse {
  recording.StreamingResponse(status: 200, headers: [], chunks: [
    recording.Chunk(data: <<"a">>, delay_ms: 0),
    recording.Chunk(data: <<"b">>, delay_ms: 500),
  ])
}

// A chunk at once, then a chunk after 10 seconds: longer than any test
// waits.
fn long_stream() -> recording.RecordedResponse {
  recording.StreamingResponse(status: 200, headers: [], chunks: [
    recording.Chunk(data: <<"a">>, delay_ms: 0),
    recording.Chunk(data: <<"b">>, delay_ms: 10_000),
  ])
}

fn timed_out(timeout_ms: Int) -> client.StreamFailure {
  client.TransportFailure(error: client.TimedOut(timeout_ms: timeout_ms))
}

fn now_milliseconds() -> Int {
  monotonic_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int
