//// Tests for start_stream() callback-based API

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import gleam/erlang/process

pub fn tests() -> TestSuite {
  describe("client.start_stream", [
    it("reports a running stream as active", fn() {
      // Arrange
      let assert Ok(handle) =
        client.start_stream(mock_server.get("/stream/slow"))

      // Act
      let active = client.is_stream_active(handle)
      client.cancel_stream_handle(handle)

      // Assert
      active
      |> should
      |> be_equal(True)
      |> or_fail_with("A stream that just started should be active")
    }),
    it("passes every chunk to on_stream_chunk", fn() {
      // Arrange
      let chunks = process.new_subject()
      let ended = process.new_subject()
      let request =
        mock_server.get("/stream/fast")
        |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
        |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
      let assert Ok(_handle) = client.start_stream(request)

      // Act
      let end = process.receive(ended, 10_000)
      let body = mailbox.drain_bits(chunks)

      // Assert
      #(end, body)
      |> should
      |> be_equal(
        #(Ok(Nil), <<
          "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
          "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
        >>),
      )
      |> or_fail_with("on_stream_chunk should get the whole body in order")
    }),
    it("calls on_stream_start with the response headers", fn() {
      // Arrange
      let started = process.new_subject()
      let request =
        mock_server.get("/stream/fast")
        |> client.on_stream_start(fn(_headers) { process.send(started, True) })

      // Act
      let assert Ok(_handle) = client.start_stream(request)
      let start = process.receive(started, 5000)

      // Assert
      start
      |> should
      |> be_equal(Ok(True))
      |> or_fail_with("on_stream_start should be called")
    }),
    it("calls on_stream_end when the stream completes", fn() {
      // Arrange
      let ended = process.new_subject()
      let request =
        mock_server.get("/stream/fast")
        |> client.on_stream_end(fn(_headers) { process.send(ended, True) })

      // Act
      let assert Ok(_handle) = client.start_stream(request)
      let end = process.receive(ended, 5000)

      // Assert
      end
      |> should
      |> be_equal(Ok(True))
      |> or_fail_with("on_stream_end should be called")
    }),
    it("calls on_stream_error when the connection is refused", fn() {
      // Arrange
      let errors = process.new_subject()
      let request =
        mock_server.closed_port("/")
        |> client.on_stream_error(fn(failure) { process.send(errors, failure) })

      // Act
      let assert Ok(_handle) = client.start_stream(request)
      let failure = process.receive(errors, 20_000)

      // Assert
      failure
      |> should
      |> be_equal(
        Ok(client.TransportFailure(client.ConnectFailed("Connection refused"))),
      )
      |> or_fail_with("on_stream_error should get the connection failure")
    }),
    it("await_stream returns after the stream ends", fn() {
      // Arrange
      let assert Ok(handle) =
        client.start_stream(mock_server.get("/stream/fast"))

      // Act
      client.await_stream(handle)

      // Assert
      client.is_stream_active(handle)
      |> should
      |> be_equal(False)
      |> or_fail_with("The stream should not be active after await_stream")
    }),
    it("cancel_stream_handle stops the stream", fn() {
      // Arrange
      let assert Ok(handle) =
        client.start_stream(mock_server.get("/stream/slow"))

      // Act
      client.cancel_stream_handle(handle)
      process.sleep(100)

      // Assert
      client.is_stream_active(handle)
      |> should
      |> be_equal(False)
      |> or_fail_with("The stream should not be active after a cancel")
    }),
    group("a failing stream", [
      it("calls on_stream_error once and no on_stream_end on a drop", fn() {
        // Arrange
        let request = mock_server.get("/stream/drop")

        // Act
        let endings = stream_endings(request)

        // Assert
        endings
        |> should
        |> be_equal(["error: Remote closed connection"])
        |> or_fail_with("A dropped stream should end with one error")
      }),
      it("calls on_stream_error once and no on_stream_end on a 500", fn() {
        // Arrange
        let request = mock_server.get("/stream/error")

        // Act
        let endings = stream_endings(request)

        // Assert
        endings
        |> should
        |> be_equal([
          "error: HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
        ])
        |> or_fail_with("A 500 response should end with one error")
      }),
      it("calls on_stream_error once and no on_stream_end on a timeout", fn() {
        // Arrange
        let request = mock_server.get("/stream/slow") |> client.timeout(300)

        // Act
        let endings = stream_endings(request)

        // Assert
        endings
        |> should
        |> be_equal(["error: Timed out after 300ms"])
        |> or_fail_with("A stream that timed out should end with one error")
      }),
      it(
        "calls on_stream_error once and no on_stream_end on a refused connection",
        fn() {
          // Arrange
          let request = mock_server.closed_port("/")

          // Act
          let endings = stream_endings(request)

          // Assert
          endings
          |> should
          |> be_equal(["error: Connection failed: Connection refused"])
          |> or_fail_with("A refused connection should end with one error")
        },
      ),
    ]),
  ])
}

// Runs `request` with start_stream() until the stream process stops, and
// returns each call of on_stream_end and on_stream_error, oldest first.
fn stream_endings(request: client.ClientRequest) -> List(String) {
  let endings = process.new_subject()
  let assert Ok(handle) =
    request
    |> client.on_stream_end(fn(_headers) { process.send(endings, "end") })
    |> client.on_stream_error(fn(failure) {
      process.send(
        endings,
        "error: " <> client.stream_failure_to_string(failure),
      )
    })
    |> client.start_stream()
  client.await_stream(handle)
  mailbox.drain(endings)
}
