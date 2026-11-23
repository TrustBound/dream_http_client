//// Error handling tests for HTTP client
////
//// Tests that verify errors are properly surfaced through send(): error
//// status codes, large and empty responses, connection failures, and the
//// text of every error.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import gleam/http
import gleam/list
import gleam/result
import gleam/string

pub fn tests() -> TestSuite {
  describe("error handling", [
    group("client.send status codes", [
      it("returns Ok for status 200", fn() {
        // Arrange
        let request = mock_server.get("/status/200")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        value
        |> should
        |> be_equal(Ok(200))
        |> or_fail_with("Status 200 should be Ok")
      }),
      it("returns Ok for status 201", fn() {
        // Arrange
        let request = mock_server.get("/status/201")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        value
        |> should
        |> be_equal(Ok(201))
        |> or_fail_with("Status 201 should be Ok")
      }),
      it("returns Ok for status 204", fn() {
        // Arrange
        let request = mock_server.get("/status/204")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        value
        |> should
        |> be_equal(Ok(204))
        |> or_fail_with("Status 204 should be Ok")
      }),
      it("returns Ok for status 399", fn() {
        // Arrange
        let request = mock_server.get("/status/399")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        value
        |> should
        |> be_equal(Ok(399))
        |> or_fail_with("Status 399 should be Ok")
      }),
      it("returns a ResponseError for status 400", fn() {
        // Arrange
        let request = mock_server.get("/status/400")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(400, <<"{\"status\":400}">>))))
        |> or_fail_with("Status 400 should be a ResponseError with its body")
      }),
      it("returns a ResponseError for status 401", fn() {
        // Arrange
        let request = mock_server.get("/status/401")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(401, <<"{\"status\":401}">>))))
        |> or_fail_with("Status 401 should be a ResponseError with its body")
      }),
      it("returns a ResponseError for status 404", fn() {
        // Arrange
        let request = mock_server.get("/status/404")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(404, <<"{\"status\":404}">>))))
        |> or_fail_with("Status 404 should be a ResponseError with its body")
      }),
      it("returns a ResponseError for status 500", fn() {
        // Arrange
        let request = mock_server.get("/status/500")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(500, <<"{\"status\":500}">>))))
        |> or_fail_with("Status 500 should be a ResponseError with its body")
      }),
      it("returns a ResponseError for status 503", fn() {
        // Arrange
        let request = mock_server.get("/status/503")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(503, <<"{\"status\":503}">>))))
        |> or_fail_with("Status 503 should be a ResponseError with its body")
      }),
    ]),
    group("client.send responses", [
      it("returns ConnectFailed when the connection is refused", fn() {
        // Arrange
        let request = mock_server.closed_port("/nonexistent")

        // Act
        let value = client.send(request)

        // Assert
        value
        |> should
        |> be_equal(
          Error(client.RequestError(client.ConnectFailed("Connection refused"))),
        )
        |> or_fail_with("A refused connection should be ConnectFailed")
      }),
      it("sends the Content-Type header of the caller", fn() {
        // Arrange
        let request =
          mock_server.request(http.Post, "/content-type")
          |> client.add_header("Content-Type", "text/plain")
          |> client.body("hello")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.body })

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"text/plain">>))
        |> or_fail_with("The server should see text/plain")
      }),
      it("reads a large body", fn() {
        // Arrange
        let request = mock_server.get("/large")

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.body })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            string.repeat(
              "This is a repeated line to create a large response body.\n",
              20_000,
            ):utf8,
          >>),
        )
        |> or_fail_with("The whole large body should arrive")
      }),
      it("reads an empty body", fn() {
        // Arrange
        let request = mock_server.get("/empty")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<>>)))
        |> or_fail_with("An empty body should be Ok")
      }),
      it("returns the status and body of a 200", fn() {
        // Arrange
        let request = mock_server.get("/text")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("The text endpoint should return 200 and its body")
      }),
      it("returns the response headers", fn() {
        // Arrange
        let request = mock_server.get("/json")

        // Act
        let value =
          client.send(request)
          |> result.map(fn(response) {
            list.find(response.headers, fn(header) {
              string.lowercase(header.name) == "content-type"
            })
            |> result.map(fn(header) { header.value })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok(Ok("application/json; charset=utf-8")))
        |> or_fail_with("The Content-Type header should come back")
      }),
      it("returns the headers of an error response", fn() {
        // Arrange
        let request = mock_server.get("/status/404")

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                list.find(response.headers, fn(header) {
                  string.lowercase(header.name) == "content-type"
                })
                |> result.map(fn(header) { header.value })
              client.RequestError(_) -> Error(Nil)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok("application/json; charset=utf-8")))
        |> or_fail_with("A ResponseError should carry the headers")
      }),
    ]),
    group("client.transport_error_to_string", [
      it("formats StreamReset", fn() {
        // Arrange
        let error =
          client.StreamReset(
            code: client.Cancel,
            description: "stream cancelled",
          )

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Stream reset (cancel): stream cancelled")
        |> or_fail_with(
          "StreamReset should format as Stream reset (cancel): stream cancelled",
        )
      }),
      it("formats Goaway", fn() {
        // Arrange
        let error = client.Goaway(code: client.NoError, description: "bye")

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("GOAWAY (no_error): bye")
        |> or_fail_with("Goaway should format as GOAWAY (no_error): bye")
      }),
      it("formats the name of every HTTP/2 error code", fn() {
        // Arrange
        let codes = [
          client.NoError,
          client.ProtocolError,
          client.InternalError,
          client.FlowControlError,
          client.SettingsTimeout,
          client.StreamClosed,
          client.FrameSizeError,
          client.RefusedStream,
          client.Cancel,
          client.CompressionError,
          client.ConnectError,
          client.EnhanceYourCalm,
          client.InadequateSecurity,
          client.Http11Required,
          client.UnknownErrorCode(name: "new_code"),
        ]

        // Act
        let value =
          list.map(codes, fn(code) {
            client.transport_error_to_string(client.StreamReset(
              code: code,
              description: "x",
            ))
          })

        // Assert
        value
        |> should
        |> be_equal([
          "Stream reset (no_error): x",
          "Stream reset (protocol_error): x",
          "Stream reset (internal_error): x",
          "Stream reset (flow_control_error): x",
          "Stream reset (settings_timeout): x",
          "Stream reset (stream_closed): x",
          "Stream reset (frame_size_error): x",
          "Stream reset (refused_stream): x",
          "Stream reset (cancel): x",
          "Stream reset (compression_error): x",
          "Stream reset (connect_error): x",
          "Stream reset (enhance_your_calm): x",
          "Stream reset (inadequate_security): x",
          "Stream reset (http_1_1_required): x",
          "Stream reset (new_code): x",
        ])
        |> or_fail_with("Each code should have its RFC name in lowercase")
      }),
      it("formats ConnectionError", fn() {
        // Arrange
        let error =
          client.ConnectionError(
            code: client.ProtocolError,
            description: "bad frame",
          )

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Connection error (protocol_error): bad frame")
        |> or_fail_with(
          "ConnectionError should format as Connection error (protocol_error): bad frame",
        )
      }),
      it("formats RemoteClosed", fn() {
        // Arrange
        let error = client.RemoteClosed

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Remote closed connection")
        |> or_fail_with(
          "RemoteClosed should format as Remote closed connection",
        )
      }),
      it("formats TimedOut", fn() {
        // Arrange
        let error = client.TimedOut(timeout_ms: 5000)

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Timed out after 5000ms")
        |> or_fail_with("TimedOut should format as Timed out after 5000ms")
      }),
      it("formats ProcessDown", fn() {
        // Arrange
        let error = client.ProcessDown(reason: "noproc")

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Process down: noproc")
        |> or_fail_with("ProcessDown should format as Process down: noproc")
      }),
      it("formats ConnectFailed", fn() {
        // Arrange
        let error = client.ConnectFailed(reason: "Connection refused")

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Connection failed: Connection refused")
        |> or_fail_with(
          "ConnectFailed should format as Connection failed: Connection refused",
        )
      }),
      it("formats Unexpected", fn() {
        // Arrange
        let error = client.Unexpected(raw: "{weird}")

        // Act
        let value = client.transport_error_to_string(error)

        // Assert
        value
        |> should
        |> be_equal("Unexpected error: {weird}")
        |> or_fail_with("Unexpected should format as Unexpected error: {weird}")
      }),
    ]),
    group("client.stream_failure_to_string", [
      it("formats an HttpFailure with its status and body", fn() {
        // Arrange
        let failure =
          client.HttpFailure(
            response: client.HttpResponse(status: 404, headers: [], body: <<
              "not found",
            >>),
          )

        // Act
        let value = client.stream_failure_to_string(failure)

        // Assert
        value
        |> should
        |> be_equal("HTTP 404: not found")
        |> or_fail_with("An HttpFailure should show its status and body")
      }),
      it("formats a TransportFailure with its transport error", fn() {
        // Arrange
        let failure =
          client.TransportFailure(error: client.TimedOut(timeout_ms: 5000))

        // Act
        let value = client.stream_failure_to_string(failure)

        // Assert
        value
        |> should
        |> be_equal("Timed out after 5000ms")
        |> or_fail_with("A TransportFailure should show its transport error")
      }),
    ]),
  ])
}
