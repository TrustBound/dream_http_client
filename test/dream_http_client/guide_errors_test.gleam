//// Tests for the snippets of the errors guide (docs/guides/errors.md).
//// Each test sends a snippet's request to the local mock server or to an
//// edge server, and asserts the exact value that the guide shows. The
//// output that the guide shows in a `text` block is a file in
//// `test/outputs/`, and the tests compare it with the real output.

import dream_http_client/client.{RequestError, TimedOut, Unexpected}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import fixtures/output_file
import fixtures/shown
import gleam/http
import gleam/int
import gleam/result
import gleam/string
import snippets/guide_errors_classify.{
  type Outcome, Done, GiveUp, TryLater, classify,
}
import snippets/guide_errors_redirects.{redirect_target}
import snippets/guide_errors_retry.{send_with_retry}
import snippets/guide_errors_timeouts.{fetch_report}

pub fn tests() -> TestSuite {
  describe("errors guide", [
    group("step 1: classify", [
      it("classify gives the outcome of each failure the guide shows", fn() {
        // Arrange
        use closing_port <- edge_server.with("close")
        use resetting_port <- edge_server.with("h2_rst")
        let resetting =
          edge_server.request(resetting_port)
          |> client.protocols(client.Http2Only)

        // Act
        let lines = [
          "send(api |> path(\"/text\"))                  -> "
            <> shown(classify(client.send(mock_server.get("/text")))),
          "send(api |> path(\"/status/404\"))            -> "
            <> shown(classify(client.send(mock_server.get("/status/404")))),
          "send(api |> path(\"/status/503\"))            -> "
            <> shown(classify(client.send(mock_server.get("/status/503")))),
          "send(api |> port(1))                        -> "
            <> shown(classify(client.send(mock_server.closed_port("/")))),
          "a server that closes the connection         -> "
            <> shown(classify(client.send(edge_server.request(closing_port)))),
          "an HTTP/2 server that resets the stream     -> "
            <> shown(classify(client.send(resetting))),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_errors_step_1"))
        |> or_fail_with("classify gives the outcomes that the guide shows")
      }),
    ]),
    group("step 2: timeouts", [
      it("fetch_report times out after 500 ms, and not after 7 s", fn() {
        // Act
        let lines = [
          "fetch_report(api, 500)    -> "
            <> shown.sent(fetch_report(api(), 500)),
          "fetch_report(api, 7000)   -> "
            <> shown.sent(fetch_report(api(), 7000)),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_errors_step_2"))
        |> or_fail_with("The slow endpoint needs 5 seconds")
      }),
      it("the default connect timeout is 15 seconds", fn() {
        // Act
        let milliseconds =
          client.get_default_connect_timeout(client.transport_config())

        // Assert
        milliseconds
        |> should
        |> be_equal(15_000)
        |> or_fail_with("The default connect timeout is 15000 ms")
      }),
    ]),
    group("step 3: redirects", [
      it("send follows a 302 to its target", fn() {
        // Act
        let result =
          client.send(mock_server.get("/redirect/302"))
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("The 302 points to /text")
      }),
      it("redirect_target reads the location of a 302", fn() {
        // Act
        let target = redirect_target(api(), "/redirect/302")

        // Assert
        target
        |> should
        |> be_equal(Ok("/text"))
        |> or_fail_with("The location of the 302 is /text")
      }),
      it("a redirect loop stops after five redirects", fn() {
        // Arrange
        use port <- edge_server.with("redirect_loop")

        // Act
        let result =
          client.send(edge_server.request(port))
          |> result.map(fn(response) { response.status })

        // Assert
        result
        |> should
        |> be_equal(
          Error(RequestError(Unexpected("Too many redirects (max 5)"))),
        )
        |> or_fail_with("A loop should end after five redirects")
      }),
    ]),
    group("step 4: retries", [
      it("send_with_retry sends a GET three times and a POST once", fn() {
        // Arrange
        use get_port <- edge_server.with("server_error")
        use post_port <- edge_server.with("server_error")
        let post = edge_server.request(post_port) |> client.method(http.Post)

        // Act
        let get_outcome = send_with_retry(edge_server.request(get_port), 3, 10)
        let post_outcome = send_with_retry(post, 3, 10)
        let lines = [
          "send_with_retry(GET request, 3, 10)    -> "
            <> shown(get_outcome)
            <> ", and the server got "
            <> requests(edge_server.requests_received(get_port)),
          "send_with_retry(POST request, 3, 10)   -> "
            <> shown(post_outcome)
            <> ", and the server got "
            <> requests(edge_server.requests_received(post_port)),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_errors_step_4"))
        |> or_fail_with("A GET is tried three times, a POST once")
      }),
      it("the client sends a GET again after a closed connection", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let _response = client.send(edge_server.request(port))

        // Assert
        edge_server.requests_received(port)
        |> should
        |> be_equal(2)
        |> or_fail_with("The server should read the GET twice")
      }),
      it("the client does not send a GET again after a timeout", fn() {
        // Arrange
        use port <- edge_server.with("silent")
        let request = edge_server.request(port) |> client.timeout(200)

        // Act
        let result = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        #(result, edge_server.requests_received(port))
        |> should
        |> be_equal(#(Error(RequestError(TimedOut(200))), 1))
        |> or_fail_with("A timeout is not sent again")
      }),
      it("the client does not send a GET again after a 500", fn() {
        // Arrange
        use port <- edge_server.with("server_error")

        // Act
        let outcome = summary(classify(client.send(edge_server.request(port))))

        // Assert
        #(outcome, edge_server.requests_received(port))
        |> should
        |> be_equal(#("TryLater HTTP 500", 1))
        |> or_fail_with("An error status is not sent again")
      }),
      it("the client sends a POST once after a closed connection", fn() {
        // Arrange
        use port <- edge_server.with("close")
        let request = edge_server.request(port) |> client.method(http.Post)

        // Act
        let _response = client.send(request)

        // Assert
        edge_server.requests_received(port)
        |> should
        |> be_equal(1)
        |> or_fail_with("The server should read the POST once")
      }),
    ]),
  ])
}

fn api() -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(mock_server.port())
}

/// The outcome as text, without the date header of a response.
fn summary(outcome: Outcome) -> String {
  case outcome {
    Done(response: response) -> "Done " <> int.to_string(response.status)
    TryLater(reason: reason) -> "TryLater " <> reason
    GiveUp(reason: reason) -> "GiveUp " <> reason
  }
}

/// The outcome as the guide shows it: a `Done` with its status, because the
/// date header of a response changes, and the other outcomes as they are.
fn shown(outcome: Outcome) -> String {
  case outcome {
    Done(response: response) ->
      "Done(response)  (status " <> int.to_string(response.status) <> ")"
    _ -> string.inspect(outcome)
  }
}

fn requests(count: Int) -> String {
  case count {
    1 -> "1 request"
    _ -> int.to_string(count) <> " requests"
  }
}
