//// Tests for stream error reason decoding robustness
////
//// Verifies that the HTTP client can decode error reasons from gun
//// regardless of the error format: transport-level errors (atoms/tuples),
//// non-UTF-8 response bodies, and connection failures. Both the
//// message-based (start_stream) and pull-based (stream_yielder) paths are
//// tested.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("stream error decoding", [
    group("connection refused", [
      it("start_stream passes ConnectFailed to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.closed_port("/anything")
          |> client.timeout(10_000)
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let failure = process.receive(errors, 10_000)

        // Assert
        failure
        |> should
        |> be_equal(
          Ok(
            client.TransportFailure(client.ConnectFailed("Connection refused")),
          ),
        )
        |> or_fail_with("on_stream_error should get ConnectFailed")
      }),
      it("stream_yielder yields ConnectFailed", fn() {
        // Arrange
        let request =
          mock_server.closed_port("/anything") |> client.timeout(10_000)

        // Act
        let results = client.stream_yielder(request) |> yielder.first

        // Assert
        results
        |> should
        |> be_equal(
          Ok(
            Error(
              client.TransportFailure(client.ConnectFailed("Connection refused")),
            ),
          ),
        )
        |> or_fail_with("The yielder should yield one ConnectFailed")
      }),
      it("send returns a RequestError with ConnectFailed", fn() {
        // Arrange
        let request =
          mock_server.closed_port("/anything") |> client.timeout(10_000)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(client.RequestError(client.ConnectFailed("Connection refused"))),
        )
        |> or_fail_with("send should return ConnectFailed")
      }),
    ]),
    group("connection dropped mid-stream", [
      it("start_stream passes RemoteClosed to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/stream/drop")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let failure = process.receive(errors, 10_000)

        // Assert
        failure
        |> should
        |> be_equal(Ok(client.TransportFailure(client.RemoteClosed)))
        |> or_fail_with("on_stream_error should get RemoteClosed")
      }),
      it("stream_yielder ends with ProcessDown noproc", fn() {
        // Arrange
        let request = mock_server.get("/stream/drop")

        // Act
        let last =
          client.stream_yielder(request)
          |> yielder.take(10)
          |> yielder.to_list
          |> list.last

        // Assert
        last
        |> should
        |> be_equal(
          Ok(Error(client.TransportFailure(client.ProcessDown("noproc")))),
        )
        |> or_fail_with("The last item should be the dropped stream error")
      }),
    ]),
    group("non-UTF-8 error body", [
      it("start_stream passes the 400 response to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/non-utf8-error")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, client.stream_failure_to_string(failure))
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let reason = process.receive(errors, 5000)

        // Assert
        reason
        |> should
        |> be_equal(Ok("HTTP 400: Error: ÀÁþÿ"))
        |> or_fail_with("on_stream_error should get the 400 response")
      }),
      it("stream_yielder yields the 400 response", fn() {
        // Arrange
        let request = mock_server.get("/non-utf8-error")

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
        |> be_equal(Ok(Error("HTTP 400: Error: ÀÁþÿ")))
        |> or_fail_with("The yielder should yield the 400 response")
      }),
      it("send returns a ResponseError with the raw 400 body", fn() {
        // Arrange
        let request = mock_server.get("/non-utf8-error")

        // Act
        let result =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, bit_array.from_string(response.body)))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        result
        |> should
        |> be_equal(Error(Ok(#(400, <<"Error: ", 192, 193, 254, 255>>))))
        |> or_fail_with("send should return the 400 response with its bytes")
      }),
    ]),
  ])
}
