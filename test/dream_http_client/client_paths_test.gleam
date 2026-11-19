//// Client paths that the feature tests do not reach: other methods,
//// protocols, default ports, timeouts, streams with no callbacks, and the
//// recorder edge cases.

import dream_http_client/client.{Http2Preferred}
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import fixtures/recorded
import fixtures/temp_directory
import fixtures/tls_server
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("client paths", [
    group("methods", [
      it("sends the Head method", fn() {
        // Arrange
        let request = mock_server.request(http.Head, "/nowhere")

        // Act
        let value = case client.send(request) {
          Error(client.ResponseError(response: response)) ->
            Ok(#(response.status, response.body))
          Ok(_) | Error(_) -> Error(Nil)
        }

        // Assert
        value
        |> should
        |> be_equal(Ok(#(404, "")))
        |> or_fail_with("The method should reach the server and get its 404")
      }),
      it("sends the Options method", fn() {
        // Arrange
        let request = mock_server.request(http.Options, "/nowhere")

        // Act
        let value = case client.send(request) {
          Error(client.ResponseError(response: response)) ->
            Ok(#(response.status, response.body))
          Ok(_) | Error(_) -> Error(Nil)
        }

        // Assert
        value
        |> should
        |> be_equal(Ok(#(404, "Route not found")))
        |> or_fail_with("The method should reach the server and get its 404")
      }),
      it("sends the Trace method", fn() {
        // Arrange
        let request = mock_server.request(http.Trace, "/nowhere")

        // Act
        let value = case client.send(request) {
          Error(client.ResponseError(response: response)) ->
            Ok(#(response.status, response.body))
          Ok(_) | Error(_) -> Error(Nil)
        }

        // Assert
        value
        |> should
        |> be_equal(Ok(#(404, "Route not found")))
        |> or_fail_with("The method should reach the server and get its 404")
      }),
      it("sends the Connect method", fn() {
        // Arrange
        let request = mock_server.request(http.Connect, "/nowhere")

        // Act
        let value = case client.send(request) {
          Error(client.ResponseError(response: response)) ->
            Ok(#(response.status, response.body))
          Ok(_) | Error(_) -> Error(Nil)
        }

        // Assert
        value
        |> should
        |> be_equal(Ok(#(404, "Route not found")))
        |> or_fail_with("The method should reach the server and get its 404")
      }),
      it("sends the Other(PURGE) method", fn() {
        // Arrange
        let request = mock_server.request(http.Other("PURGE"), "/nowhere")

        // Act
        let value = case client.send(request) {
          Error(client.ResponseError(response: response)) ->
            Ok(#(response.status, response.body))
          Ok(_) | Error(_) -> Error(Nil)
        }

        // Assert
        value
        |> should
        |> be_equal(Ok(#(404, "Route not found")))
        |> or_fail_with("The method should reach the server and get its 404")
      }),
    ]),
    group("connections and streams", [
      it("send uses Http2Preferred over TLS", fn() {
        // Arrange
        use certificates <- tls_server.with(19_969)
        let request =
          tls_server.request(certificates.port)
          |> client.protocols(Http2Preferred)
          |> client.certificate_authority_file(
            certificates.certificate_authority,
          )

        // Act
        let value = client.send(request) |> result.map(fn(r) { r.body })

        // Assert
        value
        |> should
        |> be_equal(Ok("hello over tls"))
        |> or_fail_with("Http2Preferred should work over TLS")
      }),
      it("send with no port uses the default port", fn() {
        // Arrange
        let request =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("localhost")
          |> client.path("/")

        // Act
        let value = client.send(request)

        // Assert
        value
        |> should
        |> be_equal(
          Error(client.RequestError(client.ConnectFailed("Connection refused"))),
        )
        |> or_fail_with("Nothing listens on port 80 in the tests")
      }),
      it("stream_yielder with no port uses the default port", fn() {
        // Arrange
        let request =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("localhost")
          |> client.path("/")

        // Act
        let value = client.stream_yielder(request) |> yielder.first

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            Error(
              client.TransportFailure(client.ConnectFailed("Connection refused")),
            ),
          ),
        )
        |> or_fail_with("Nothing listens on port 80 in the tests")
      }),
      it("start_stream reports a timeout", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/stream/slow")
          |> client.timeout(100)
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let value = process.receive(errors, 5000)

        // Assert
        value
        |> should
        |> be_equal(Ok(client.TransportFailure(client.TimedOut(100))))
        |> or_fail_with("A slow stream should time out")
      }),
      it("start_stream with no callbacks completes", fn() {
        // Arrange
        let request = mock_server.get("/stream/fast")

        // Act
        let assert Ok(handle) = client.start_stream(request)
        client.await_stream(handle)
        let value = client.is_stream_active(handle)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("A stream with no callbacks should still finish")
      }),
      it("start_stream with no error callback ends after an error", fn() {
        // Arrange
        let request = mock_server.closed_port("/")

        // Act
        let assert Ok(handle) = client.start_stream(request)
        client.await_stream(handle)
        let value = client.is_stream_active(handle)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("A failed stream with no callback should still finish")
      }),
      it("start_stream with no error callback ends after a timeout", fn() {
        // Arrange
        let request = mock_server.get("/stream/slow") |> client.timeout(100)

        // Act
        let assert Ok(handle) = client.start_stream(request)
        client.await_stream(handle)
        let value = client.is_stream_active(handle)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with(
          "A timed out stream with no callback should still finish",
        )
      }),
    ]),
    group("recorder edge cases", [
      it("stream_yielder yields an error for an ambiguous recording", fn() {
        // Arrange
        let path = temp_directory.path("cp_yield_ambiguous")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("one"),
            ),
            "first",
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("two"),
            ),
            "second",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.to_list
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal([
          Error(
            client.TransportFailure(client.Unexpected(
              "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
            )),
          ),
        ])
        |> or_fail_with("An ambiguous match should be one error")
      }),
      it("start_stream passes an ambiguous recording to on_stream_error", fn() {
        // Arrange
        let path = temp_directory.path("cp_start_ambiguous")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("one"),
            ),
            "first",
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("two"),
            ),
            "second",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()
        let errors = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let value = process.receive(errors, 5000)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            client.TransportFailure(client.Unexpected(
              "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
            )),
          ),
        )
        |> or_fail_with("An ambiguous match should reach on_stream_error")
      }),
      it("start_stream plays back with no callbacks", fn() {
        // Arrange
        let path = temp_directory.path("cp_start_playback_quiet")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recorded.text_recording(),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let assert Ok(handle) =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.start_stream
        client.await_stream(handle)
        let value = client.is_stream_active(handle)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("Playback with no callbacks should finish")
      }),
      it("start_stream plays back a stream with no callbacks", fn() {
        // Arrange
        let path = temp_directory.path("cp_start_playback_stream_quiet")
        let streaming =
          recording.Recording(
            request: recorded.text_request(),
            response: recording.StreamingResponse(
              status: 200,
              headers: [],
              chunks: [
                recording.Chunk(data: <<"x">>, delay_ms: 0),
              ],
            ),
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, streaming, "k")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let assert Ok(handle) =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.start_stream
        client.await_stream(handle)
        let value = client.is_stream_active(handle)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("Stream playback with no callbacks should finish")
      }),
      it("stream_yielder in record mode yields a refused connection", fn() {
        // Arrange
        let path = temp_directory.path("cp_yield_record_refused")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let value =
          mock_server.closed_port("/text")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.first
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(Error(client.TransportFailure(client.ProcessDown("noproc")))),
        )
        |> or_fail_with("The record path should yield the start failure")
      }),
      it("stream_yielder in record mode saves the chunks before a drop", fn() {
        // Arrange
        let path = temp_directory.path("cp_yield_record_drop")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _items =
          mock_server.get("/stream/drop")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.take(10)
          |> yielder.to_list
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.StreamingResponse(status, _headers, chunks) -> #(
                  status,
                  list.map(chunks, fn(chunk) { chunk.data }) |> bit_array.concat,
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
        |> be_equal(Ok([#(200, <<"Drop chunk 1\nDrop chunk 2\n">>)]))
        |> or_fail_with("The chunks before the drop should be saved")
      }),
      it("start_stream in record mode saves the chunks before a drop", fn() {
        // Arrange
        let path = temp_directory.path("cp_start_record_drop")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/drop")
          |> client.recorder(rec)
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let assert Ok(False) = process.receive(ended, 10_000)
        process.sleep(100)
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.StreamingResponse(status, _headers, chunks) -> #(
                  status,
                  list.map(chunks, fn(chunk) { chunk.data }) |> bit_array.concat,
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
        |> be_equal(Ok([#(200, <<"Drop chunk 1\nDrop chunk 2\n">>)]))
        |> or_fail_with("The chunks before the drop should be saved")
      }),
    ]),
  ])
}
