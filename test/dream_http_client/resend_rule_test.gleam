//// Tests for the rule that decides when the client sends a request once
//// more on another connection (RFC 9110, section 9.2.2; RFC 9113, sections
//// 6.8 and 8.7).
////
//// The `close` server reads a request and closes the connection with no
//// answer, so the server can have processed it. The client sends an
//// idempotent request (GET, PUT, DELETE) once more, and a POST or PATCH
//// only once. The server counts the requests it read.

import dream_http_client/client.{
  type SendError, type StreamFailure, type StreamMessage, ProcessDown,
  RemoteClosed, RequestError, StreamError, TransportFailure,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/http
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("sending a request again after the connection closed", [
    group("send", [
      it("sends a POST once", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = send_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 1))
        |> or_fail_with("A POST must not be sent again")
      }),
      it("sends a PATCH once", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = send_and_count(port, http.Patch)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 1))
        |> or_fail_with("A PATCH must not be sent again")
      }),
      it("sends a POST once when its connection process stopped", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let results = process.new_subject()
        let post = request(port, http.Post) |> client.timeout(600)
        process.spawn(fn() { process.send(results, client.send(post)) })
        let stopped = edge_server.stop_connections(port)

        // Act
        let result = process.receive(results, 5000)

        // Assert
        #(stopped, result, edge_server.requests_received(port))
        |> should
        |> be_equal(#(1, Ok(Error(RequestError(ProcessDown("shutdown")))), 1))
        |> or_fail_with("A POST on a stopped connection must not be sent again")
      }),
      it("sends a POST again when gun stopped before it took the request", fn() {
        // Arrange
        use port <- edge_server.with("empty")
        let _ = client.send(edge_server.request(port))
        let suspended = edge_server.suspend_connections(port)
        let results = process.new_subject()
        let post = request(port, http.Post)
        process.spawn(fn() {
          process.send(results, post |> client.send() |> result.map(status))
        })
        let lost = edge_server.lose_connections(port)

        // Act
        let result = process.receive(results, 5000)

        // Assert
        #(suspended, lost, result, edge_server.requests_received(port))
        |> should
        |> be_equal(#(1, 1, Ok(Ok(200)), 2))
        |> or_fail_with("A request that gun never took should be sent again")
      }),
      it("sends a GET twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = send_and_count(port, http.Get)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 2))
        |> or_fail_with("A GET should be sent once more")
      }),
      it("sends a PUT twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = send_and_count(port, http.Put)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 2))
        |> or_fail_with("A PUT should be sent once more")
      }),
      it("sends a DELETE twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = send_and_count(port, http.Delete)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 2))
        |> or_fail_with("A DELETE should be sent once more")
      }),
    ]),
    group("stream_yielder", [
      it("sends a POST once", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = yield_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#([Error(TransportFailure(RemoteClosed))], 1))
        |> or_fail_with("A streamed POST must not be sent again")
      }),
      it("sends a GET twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = yield_and_count(port, http.Get)

        // Assert
        outcome
        |> should
        |> be_equal(#([Error(TransportFailure(RemoteClosed))], 2))
        |> or_fail_with("A streamed GET should be sent once more")
      }),
    ]),
    group("start_stream", [
      it("sends a POST once", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = start_stream_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#(Ok(TransportFailure(RemoteClosed)), 1))
        |> or_fail_with("A POST from start_stream must not be sent again")
      }),
      it("sends a GET twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = start_stream_and_count(port, http.Get)

        // Assert
        outcome
        |> should
        |> be_equal(#(Ok(TransportFailure(RemoteClosed)), 2))
        |> or_fail_with("A GET from start_stream should be sent once more")
      }),
    ]),
    group("stream_to", [
      it("sends a POST once", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = stream_to_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#(Ok(TransportFailure(RemoteClosed)), 1))
        |> or_fail_with("A POST from stream_to must not be sent again")
      }),
      it("sends a GET twice", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = stream_to_and_count(port, http.Get)

        // Assert
        outcome
        |> should
        |> be_equal(#(Ok(TransportFailure(RemoteClosed)), 2))
        |> or_fail_with("A GET from stream_to should be sent once more")
      }),
    ]),
    group("HTTP/2", [
      it("sends a POST once when the connection closed", fn() {
        // Arrange
        use port <- edge_server.with("h2_close")

        // Act
        let outcome = send_http2_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 1))
        |> or_fail_with("A POST on a closed HTTP/2 connection is sent once")
      }),
      it("sends a GET twice when the connection closed", fn() {
        // Arrange
        use port <- edge_server.with("h2_close")

        // Act
        let outcome = send_http2_and_count(port, http.Get)

        // Assert
        outcome
        |> should
        |> be_equal(#(Error(RequestError(RemoteClosed)), 2))
        |> or_fail_with("A GET on a closed HTTP/2 connection is sent again")
      }),
      it("sends a POST again after a GOAWAY that did not keep it", fn() {
        // Arrange
        use port <- edge_server.with("h2_goaway")

        // Act
        let outcome = send_http2_and_count(port, http.Post)

        // Assert
        outcome
        |> should
        |> be_equal(#(
          Error(
            RequestError(client.Goaway(
              code: client.NoError,
              description: "The connection is going away.",
            )),
          ),
          2,
        ))
        |> or_fail_with("A GOAWAY that did not keep the stream allows a resend")
      }),
      it("sends a POST again after REFUSED_STREAM", fn() {
        // Arrange
        use port <- edge_server.with("h2s_refuse_first")

        // Act
        let outcome =
          request(port, http.Post)
          |> client.protocols(client.Http2Only)
          |> client.send()
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        outcome
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with("A refused stream was not processed, so it is resent")
      }),
    ]),
  ])
}

fn request(port: Int, method: http.Method) -> client.ClientRequest {
  edge_server.request(port)
  |> client.method(method)
  |> client.body("order=42")
}

fn status(response: client.HttpResponse) -> Int {
  response.status
}

fn send_and_count(
  port: Int,
  method: http.Method,
) -> #(Result(Int, SendError), Int) {
  let result =
    request(port, method)
    |> client.send()
    |> result.map(fn(response) { response.status })
  #(result, edge_server.requests_received(port))
}

fn send_http2_and_count(
  port: Int,
  method: http.Method,
) -> #(Result(Int, SendError), Int) {
  let result =
    request(port, method)
    |> client.protocols(client.Http2Only)
    |> client.send()
    |> result.map(fn(response) { response.status })
  #(result, edge_server.requests_received(port))
}

fn yield_and_count(
  port: Int,
  method: http.Method,
) -> #(List(Result(BytesTree, StreamFailure)), Int) {
  let items =
    request(port, method)
    |> client.stream_yielder()
    |> yielder.take(5)
    |> yielder.to_list()
  #(items, edge_server.requests_received(port))
}

fn start_stream_and_count(
  port: Int,
  method: http.Method,
) -> #(Result(StreamFailure, Nil), Int) {
  let failures = process.new_subject()
  let started =
    request(port, method)
    |> client.on_stream_error(fn(failure) { process.send(failures, failure) })
    |> client.start_stream()
  let failure = case started {
    Ok(_handle) -> process.receive(failures, 5000)
    Error(_reason) -> Error(Nil)
  }
  #(failure, edge_server.requests_received(port))
}

fn stream_to_and_count(
  port: Int,
  method: http.Method,
) -> #(Result(StreamFailure, Nil), Int) {
  let inbox = process.new_subject()
  let started = request(port, method) |> client.stream_to(inbox)
  let failure = case started {
    Ok(_request_id) -> receive_failure(inbox)
    Error(_reason) -> Error(Nil)
  }
  #(failure, edge_server.requests_received(port))
}

/// Receives messages until the stream fails or ends.
fn receive_failure(
  inbox: process.Subject(StreamMessage),
) -> Result(StreamFailure, Nil) {
  case process.receive(inbox, 5000) {
    Ok(StreamError(error: failure, ..)) -> Ok(failure)
    Ok(_other) -> receive_failure(inbox)
    Error(Nil) -> Error(Nil)
  }
}
