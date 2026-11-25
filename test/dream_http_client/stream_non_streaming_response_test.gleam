//// Regression tests for non-streaming upstream responses during streaming
////
//// When a streaming HTTP request is made via start_stream/stream_yielder and
//// the upstream returns a non-streaming response (e.g. HTTP 401/500 with a
//// body), the gun shim detects non-2xx status codes and surfaces them as
//// errors through the existing error paths.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import gleam/bytes_tree
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("non-2xx responses while streaming", [
    group("start_stream", [
      it("start_stream passes a 401 to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/401")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, client.stream_failure_to_string(failure))
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let reason = process.receive(errors, 3000)

        // Assert
        reason
        |> should
        |> be_equal(Ok("HTTP 401: {\"status\":401}"))
        |> or_fail_with("on_stream_error should get the 401 status and body")
      }),
      it("start_stream passes a 500 to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/500")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, client.stream_failure_to_string(failure))
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let reason = process.receive(errors, 3000)

        // Assert
        reason
        |> should
        |> be_equal(Ok("HTTP 500: {\"status\":500}"))
        |> or_fail_with("on_stream_error should get the 500 status and body")
      }),
      it("start_stream passes a 403 to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/403")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, client.stream_failure_to_string(failure))
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let reason = process.receive(errors, 3000)

        // Assert
        reason
        |> should
        |> be_equal(Ok("HTTP 403: {\"status\":403}"))
        |> or_fail_with("on_stream_error should get the 403 status and body")
      }),
      it("start_stream passes a 429 to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/429")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, client.stream_failure_to_string(failure))
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let reason = process.receive(errors, 3000)

        // Assert
        reason
        |> should
        |> be_equal(Ok("HTTP 429: {\"status\":429}"))
        |> or_fail_with("on_stream_error should get the 429 status and body")
      }),
      it("the stream process ends after the error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/401")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })
        let assert Ok(handle) = client.start_stream(request)
        let assert Ok(_failure) = process.receive(errors, 3000)

        // Act
        client.await_stream(handle)

        // Assert
        client.is_stream_active(handle)
        |> should
        |> be_equal(False)
        |> or_fail_with("The stream process should end after the error")
      }),
      it("the HttpFailure carries the response headers", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/401")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let content_type =
          process.receive(errors, 3000)
          |> result.try(fn(failure) {
            case failure {
              client.HttpFailure(response) ->
                list.find(response.headers, fn(header) {
                  string.lowercase(header.name) == "content-type"
                })
                |> result.map(fn(header) { header.value })
              client.TransportFailure(_) -> Error(Nil)
            }
          })

        // Assert
        content_type
        |> should
        |> be_equal(Ok("application/json; charset=utf-8"))
        |> or_fail_with("The failure should carry the Content-Type header")
      }),
      it("a 2xx stream still delivers every chunk", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/fast")
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
        let assert Ok(_handle) = client.start_stream(request)

        // Act
        let end = process.receive(ended, 5000)
        let body = mailbox.drain_bits(chunks)

        // Assert
        #(end, body)
        |> should
        |> be_equal(
          #(Ok(True), <<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("A 2xx stream should still deliver every chunk")
      }),
    ]),
    group("stream_yielder", [
      it("stream_yielder yields a 401 as an error", fn() {
        // Arrange
        let request = mock_server.get("/status/401")

        // Act
        let first =
          client.stream_yielder(request)
          |> yielder.first
          |> result.map(fn(item) {
            result.map_error(item, client.stream_failure_to_string)
          })

        // Assert
        first
        |> should
        |> be_equal(Ok(Error("HTTP 401: {\"status\":401}")))
        |> or_fail_with("The yielder should yield the 401 status and body")
      }),
      it("stream_yielder yields a 500 as an error", fn() {
        // Arrange
        let request = mock_server.get("/status/500")

        // Act
        let first =
          client.stream_yielder(request)
          |> yielder.first
          |> result.map(fn(item) {
            result.map_error(item, client.stream_failure_to_string)
          })

        // Assert
        first
        |> should
        |> be_equal(Ok(Error("HTTP 500: {\"status\":500}")))
        |> or_fail_with("The yielder should yield the 500 status and body")
      }),
      it("stream_yielder yields a 422 as an error", fn() {
        // Arrange
        let request = mock_server.get("/status/422")

        // Act
        let first =
          client.stream_yielder(request)
          |> yielder.first
          |> result.map(fn(item) {
            result.map_error(item, client.stream_failure_to_string)
          })

        // Assert
        first
        |> should
        |> be_equal(Ok(Error("HTTP 422: {\"status\":422}")))
        |> or_fail_with("The yielder should yield the 422 status and body")
      }),
      it("a 2xx stream still yields every chunk", fn() {
        // Arrange
        let request = mock_server.get("/stream/fast")

        // Act
        let body =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        body
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("A 2xx stream should still yield every chunk")
      }),
    ]),
  ])
}
