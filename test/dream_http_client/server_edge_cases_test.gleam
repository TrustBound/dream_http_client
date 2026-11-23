//// Server edge cases that the mock server cannot produce: redirect loops,
//// trailers, stalled bodies, closed and killed connections, HTTP/2
//// RST_STREAM, GOAWAY and connection errors, DNS and TLS handshake
//// failures, and empty and partial streamed bodies. Each test starts its
//// own `edge_server` on a free port.

import dream_http_client/client.{
  ConnectFailed, ConnectionError, Header, HttpFailure, HttpResponse, ProcessDown,
  RemoteClosed, RequestError, StreamReset, TimedOut, TransportFailure,
  Unexpected,
}
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import fixtures/temp_directory
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/result
import gleam/yielder

const connection_error_description =
  "DATA frames MUST be associated with a stream. (RFC7540 6.1)"

pub fn tests() -> TestSuite(Nil) {
  describe("server edge cases", [
    group("send", [
      it("gives up after five redirects", fn() {
        // Arrange
        use port <- edge_server.with("redirect_loop")
        let request = edge_server.request(port)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(RequestError(Unexpected("Too many redirects (max 5)"))),
        )
        |> or_fail_with("A redirect loop should stop after five redirects")
      }),
      it("reports a redirect location that is not a URL", fn() {
        // Arrange
        use port <- edge_server.with("bad_location")
        let request = edge_server.request(port)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(Unexpected("invalid_uri"))))
        |> or_fail_with("A location with a space should be rejected")
      }),
      it("returns a redirect that has no location", fn() {
        // Arrange
        let request = mock_server.get("/status/302")

        // Act
        let status = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        status
        |> should
        |> be_equal(Ok(302))
        |> or_fail_with("A redirect with no location is the final response")
      }),
      it("reads a chunked body that ends with trailers", fn() {
        // Arrange
        use port <- edge_server.with("trailers")
        let request = edge_server.request(port)

        // Act
        let body = client.send(request) |> result.map(fn(r) { r.body })

        // Assert
        body
        |> should
        |> be_equal(Ok(<<"hello">>))
        |> or_fail_with("The body before the trailers should be returned")
      }),
      it("times out when the server never answers", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let request = edge_server.request(port) |> client.timeout(200)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(200))))
        |> or_fail_with("A server with no answer should time out")
      }),
      it("times out when the body stops", fn() {
        // Arrange
        use port <- edge_server.with("stall_body")
        let request = edge_server.request(port) |> client.timeout(200)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(200))))
        |> or_fail_with("A body that stops should time out")
      }),
      it("reports a server that closes the connection", fn() {
        // Arrange
        use port <- edge_server.with("close")
        let request = edge_server.request(port)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(RemoteClosed)))
        |> or_fail_with("A closed connection should give RemoteClosed")
      }),
      it("reports a connection process that stops", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let results = process.new_subject()
        let request = edge_server.request(port) |> client.timeout(5000)
        process.spawn(fn() { process.send(results, client.send(request)) })
        let killed = edge_server.kill_connections(port)

        // Act
        let result = process.receive(results, 5000)

        // Assert
        #(killed, result)
        |> should
        |> be_equal(#(1, Ok(Error(RequestError(ProcessDown("killed"))))))
        |> or_fail_with("A killed connection should give ProcessDown")
      }),
      it("sends again when the connection lost its socket", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let results = process.new_subject()
        let request = edge_server.request(port) |> client.timeout(600)
        process.spawn(fn() { process.send(results, client.send(request)) })
        let stopped = edge_server.stop_connections(port)

        // Act
        let result = process.receive(results, 5000)

        // Assert
        #(stopped, result)
        |> should
        |> be_equal(#(1, Ok(Error(RequestError(TimedOut(600))))))
        |> or_fail_with(
          "The request should go to a new connection and time out there",
        )
      }),
      it("uses a new connection after the server closed the old one", fn() {
        // Arrange
        use port <- edge_server.with("close_after_response")
        let request = edge_server.request(port)
        let _ = client.send(request)

        // Act
        let result =
          client.send(request)
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with("The second request should get a new connection")
      }),
      it("reports an HTTP/2 stream reset", fn() {
        // Arrange
        use port <- edge_server.with("h2_rst")
        let request =
          edge_server.request(port) |> client.protocols(client.Http2Only)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            RequestError(StreamReset(
              code: "internal_error",
              description: "Stream reset by server.",
            )),
          ),
        )
        |> or_fail_with("RST_STREAM should give StreamReset")
      }),
      it("sends again once, then reports an HTTP/2 GOAWAY", fn() {
        // Arrange
        use port <- edge_server.with("h2_goaway")
        let request =
          edge_server.request(port) |> client.protocols(client.Http2Only)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            RequestError(Unexpected(
              "{goaway,no_error,'The connection is going away.'}",
            )),
          ),
        )
        |> or_fail_with("A second GOAWAY should be reported")
      }),
      it("reports an HTTP/2 connection error", fn() {
        // Arrange
        use port <- edge_server.with("h2_connection_error")
        let request =
          edge_server.request(port) |> client.protocols(client.Http2Only)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            RequestError(ConnectionError(
              code: "protocol_error",
              description: connection_error_description,
            )),
          ),
        )
        |> or_fail_with("A protocol error should give ConnectionError")
      }),
      it("reports a connect timeout that gun rejects", fn() {
        // Arrange
        // A new port, so the request opens a new connection.
        use port <- edge_server.with("silent")
        let request = edge_server.request(port) |> client.connect_timeout(-1)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(RequestError(ConnectFailed("{options,{connect_timeout,-1}}"))),
        )
        |> or_fail_with("gun should reject a negative connect timeout")
      }),
      it("reports a host that DNS cannot find", fn() {
        // Arrange
        let request =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("nonexistent.invalid")
          |> client.port(80)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(RequestError(ConnectFailed("DNS resolution failed (NXDOMAIN)"))),
        )
        |> or_fail_with("An unknown host should give NXDOMAIN")
      }),
      it("times out when the TLS handshake never ends", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let request =
          edge_server.request(port)
          |> client.scheme(http.Https)
          |> client.connect_timeout(300)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(ConnectFailed("Connection timed out"))))
        |> or_fail_with("A TLS server with no answer should time out")
      }),
    ]),
    group("stream_yielder", [
      it("yields the body of a chunked response that ends with trailers", fn() {
        // Arrange
        use port <- edge_server.with("trailers")
        let request = edge_server.request(port)

        // Act
        let chunks =
          client.stream_yielder(request)
          |> yielder.map(result.map(_, bytes_tree.to_bit_array))
          |> yielder.to_list

        // Assert
        chunks
        |> should
        |> be_equal([Ok(<<"hello">>)])
        |> or_fail_with("The body before the trailers should be yielded")
      }),
      it("yields nothing for an empty body", fn() {
        // Arrange
        let request = mock_server.get("/empty")

        // Act
        let chunks =
          client.stream_yielder(request)
          |> yielder.map(result.map(_, bytes_tree.to_bit_array))
          |> yielder.to_list

        // Assert
        chunks
        |> should
        |> be_equal([])
        |> or_fail_with("An empty body should end the stream at once")
      }),
      it("yields a body with the identity content encoding", fn() {
        // Arrange
        let request = mock_server.get("/identity")

        // Act
        let chunks =
          client.stream_yielder(request)
          |> yielder.map(result.map(_, bytes_tree.to_bit_array))
          |> yielder.to_list

        // Assert
        chunks
        |> should
        |> be_equal([Ok(<<"Hello, World!">>)])
        |> or_fail_with("An identity body should pass through")
      }),
      it("yields a timeout when the body stops", fn() {
        // Arrange
        use port <- edge_server.with("stall_body")
        let request = edge_server.request(port) |> client.timeout(200)

        // Act
        let first = client.stream_yielder(request) |> yielder.first

        // Assert
        first
        |> should
        |> be_equal(Ok(Error(TransportFailure(TimedOut(200)))))
        |> or_fail_with("A body that stops should time out")
      }),
      it("yields an HTTP failure with an empty body when the body stops", fn() {
        // Arrange
        use port <- edge_server.with("error_stall")
        let request = edge_server.request(port) |> client.timeout(200)

        // Act
        let first = client.stream_yielder(request) |> yielder.first

        // Assert
        first
        |> should
        |> be_equal(
          Ok(
            Error(
              HttpFailure(
                HttpResponse(
                  status: 500,
                  headers: [Header("content-length", "10")],
                  body: <<>>,
                ),
              ),
            ),
          ),
        )
        |> or_fail_with("A 500 whose body stops should have an empty body")
      }),
      it("yields an HTTP/2 connection error", fn() {
        // Arrange
        use port <- edge_server.with("h2_connection_error")
        let request =
          edge_server.request(port) |> client.protocols(client.Http2Only)

        // Act
        let first = client.stream_yielder(request) |> yielder.first

        // Assert
        first
        |> should
        |> be_equal(
          Ok(
            Error(
              TransportFailure(ConnectionError(
                code: "protocol_error",
                description: connection_error_description,
              )),
            ),
          ),
        )
        |> or_fail_with("A protocol error should give ConnectionError")
      }),
      it("records the status 206 of a partial response", fn() {
        // Arrange
        use port <- edge_server.with("content_range")
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("edge_yielder_content_range"))
          |> mode("record")
          |> start()
        let request = edge_server.request(port) |> client.recorder(rec)

        // Act
        let _ = client.stream_yielder(request) |> yielder.to_list
        let statuses =
          recorder.get_recordings(rec)
          |> list.map(fn(r) { r.response.status })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        statuses
        |> should
        |> be_equal([206])
        |> or_fail_with("A 206 response should be recorded as 206")
      }),
      it("records an empty body with no chunks", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("edge_yielder_empty"))
          |> mode("record")
          |> start()
        let request = mock_server.get("/empty") |> client.recorder(rec)

        // Act
        let chunks = client.stream_yielder(request) |> yielder.to_list
        let recorded =
          recorder.get_recordings(rec)
          |> list.map(fn(r) {
            case r.response {
              recording.StreamingResponse(status, _, chunks) ->
                Ok(#(status, chunks))
              recording.BlockingResponse(_, _, _) -> Error(Nil)
            }
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        #(chunks, recorded)
        |> should
        |> be_equal(#([], [Ok(#(200, []))]))
        |> or_fail_with("An empty body should be saved with no chunks")
      }),
    ]),
    group("start_stream", [
      it("calls on_stream_end for an empty body", fn() {
        // Arrange
        let ended = process.new_subject()
        let request =
          mock_server.get("/empty")
          |> client.on_stream_end(fn(headers) { process.send(ended, headers) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let end = process.receive(ended, 5000)

        // Assert
        end
        |> should
        |> be_equal(Ok([]))
        |> or_fail_with("An empty body should end the stream at once")
      }),
      it("passes an HTTP/2 connection error to on_stream_error", fn() {
        // Arrange
        use port <- edge_server.with("h2_connection_error")
        let errors = process.new_subject()
        let request =
          edge_server.request(port)
          |> client.protocols(client.Http2Only)
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let failure = process.receive(errors, 5000)

        // Assert
        failure
        |> should
        |> be_equal(
          Ok(
            TransportFailure(ConnectionError(
              code: "protocol_error",
              description: connection_error_description,
            )),
          ),
        )
        |> or_fail_with("A protocol error should give ConnectionError")
      }),
      it("records the trailers as the headers of the recording", fn() {
        // Arrange
        use port <- edge_server.with("trailers")
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("edge_start_trailers"))
          |> mode("record")
          |> start()
        let ended = process.new_subject()
        let request =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let _ = process.receive(ended, 5000)
        let headers =
          recorder.get_recordings(rec)
          |> list.map(fn(r) { r.response.headers })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        headers
        |> should
        |> be_equal([[#("x-checksum", "abc")]])
        |> or_fail_with("The trailers should be the recorded headers")
      }),
      it("records the status 206 of a partial response", fn() {
        // Arrange
        use port <- edge_server.with("content_range")
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("edge_start_content_range"))
          |> mode("record")
          |> start()
        let ended = process.new_subject()
        let request =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let _ = process.receive(ended, 5000)
        let statuses =
          recorder.get_recordings(rec)
          |> list.map(fn(r) { r.response.status })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        statuses
        |> should
        |> be_equal([206])
        |> or_fail_with("A 206 response should be recorded as 206")
      }),
    ]),
  ])
}
