//// Tests for `client.to_error`, which maps each `TransportError` to the
//// shared error of the Dream packages.

import dream_errors
import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/doc_client_to_error

pub fn tests() -> TestSuite {
  describe("client.to_error", [
    it("maps TimedOut to Timeout", fn() {
      // Arrange
      let error = client.TimedOut(timeout_ms: 5000)

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Timeout(
        "the HTTP request got no response in 5000 ms",
        client.TimedOut(timeout_ms: 5000),
      ))
      |> or_fail_with("Should maps TimedOut to Timeout")
    }),
    it("maps ConnectFailed to Unavailable", fn() {
      // Arrange
      let error = client.ConnectFailed(reason: "Connection refused")

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Unavailable(
        "the HTTP client could not connect to the server: Connection refused",
        client.ConnectFailed(reason: "Connection refused"),
      ))
      |> or_fail_with("Should maps ConnectFailed to Unavailable")
    }),
    it("maps RemoteClosed to Failed", fn() {
      // Arrange
      let error = client.RemoteClosed

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: Remote closed connection",
        client.RemoteClosed,
      ))
      |> or_fail_with("Should maps RemoteClosed to Failed")
    }),
    it("maps ConnectionError to Failed", fn() {
      // Arrange
      let error =
        client.ConnectionError(
          code: client.ProtocolError,
          description: "bad frame",
        )

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: Connection error (protocol_error): bad frame",
        client.ConnectionError(
          code: client.ProtocolError,
          description: "bad frame",
        ),
      ))
      |> or_fail_with("Should maps ConnectionError to Failed")
    }),
    it("maps StreamReset to Failed", fn() {
      // Arrange
      let error =
        client.StreamReset(code: client.RefusedStream, description: "refused")

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: Stream reset (refused_stream): refused",
        client.StreamReset(code: client.RefusedStream, description: "refused"),
      ))
      |> or_fail_with("Should maps StreamReset to Failed")
    }),
    it("maps Goaway to Failed", fn() {
      // Arrange
      let error = client.Goaway(code: client.NoError, description: "going away")

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: GOAWAY (no_error): going away",
        client.Goaway(code: client.NoError, description: "going away"),
      ))
      |> or_fail_with("Should maps Goaway to Failed")
    }),
    it("maps ProcessDown to Failed", fn() {
      // Arrange
      let error = client.ProcessDown(reason: "killed")

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: Process down: killed",
        client.ProcessDown(reason: "killed"),
      ))
      |> or_fail_with("Should maps ProcessDown to Failed")
    }),
    it("maps Unexpected to Failed", fn() {
      // Arrange
      let error = client.Unexpected(raw: "{weird}")

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: Unexpected error: {weird}",
        client.Unexpected(raw: "{weird}"),
      ))
      |> or_fail_with("Should maps Unexpected to Failed")
    }),
    it("maps NoRecording to Failed", fn() {
      // Arrange
      let error =
        client.NoRecording(
          method: "GET",
          url: "http://localhost/users",
          directory: "test/recordings",
          nearest: [],
        )

      // Act
      let result = client.to_error(error)

      // Assert
      result
      |> should
      |> be_equal(dream_errors.Failed(
        "the HTTP request failed: No recording matches GET http://localhost/users\nNo recording in test/recordings has this method and path",
        client.NoRecording(
          method: "GET",
          url: "http://localhost/users",
          directory: "test/recordings",
          nearest: [],
        ),
      ))
      |> or_fail_with("Should maps NoRecording to Failed")
    }),
    it("the doc snippet writes a log line for a refused connection", fn() {
      // Arrange
      let error = client.ConnectFailed(reason: "Connection refused")

      // Act
      let line = doc_client_to_error.log_line(error)

      // Assert
      line
      |> should
      |> be_equal(
        "unavailable: the HTTP client could not connect to the server: Connection refused",
      )
      |> or_fail_with("Should write the kind and the message")
    }),
  ])
}
