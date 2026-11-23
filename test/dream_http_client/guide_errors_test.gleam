//// Tests for the snippets of the errors guide (docs/guides/errors.md).
//// Each test sends a snippet's request to the local mock server or to an
//// edge server, and asserts the exact value that the guide shows.

import dream_http_client/client.{RequestError, TimedOut, Unexpected}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import gleam/http
import gleam/int
import gleam/result
import snippets/guide_errors_classify.{
  type Outcome, Done, GiveUp, TryLater, classify,
}
import snippets/guide_errors_redirects.{redirect_target}
import snippets/guide_errors_retry.{send_with_retry}
import snippets/guide_errors_timeouts.{fetch_report}

pub fn tests() -> TestSuite {
  describe("errors guide", [
    group("step 1: classify", [
      it("gives Done for a 200", fn() {
        // Act
        let outcome = summary(classify(client.send(mock_server.get("/text"))))

        // Assert
        outcome
        |> should
        |> be_equal("Done 200")
        |> or_fail_with("A 200 is done")
      }),
      it("gives up on a 404", fn() {
        // Act
        let outcome =
          summary(classify(client.send(mock_server.get("/status/404"))))

        // Assert
        outcome
        |> should
        |> be_equal("GiveUp HTTP 404")
        |> or_fail_with("A 404 is final")
      }),
      it("tries a 503 later", fn() {
        // Act
        let outcome =
          summary(classify(client.send(mock_server.get("/status/503"))))

        // Assert
        outcome
        |> should
        |> be_equal("TryLater HTTP 503")
        |> or_fail_with("A 503 can pass")
      }),
      it("tries a refused connection later", fn() {
        // Act
        let outcome =
          summary(classify(client.send(mock_server.closed_port("/"))))

        // Assert
        outcome
        |> should
        |> be_equal("TryLater Connection failed: Connection refused")
        |> or_fail_with("A refused connection can pass")
      }),
      it("tries a closed connection later", fn() {
        // Arrange
        use port <- edge_server.with("close")

        // Act
        let outcome = summary(classify(client.send(edge_server.request(port))))

        // Assert
        outcome
        |> should
        |> be_equal("TryLater Remote closed connection")
        |> or_fail_with("A closed connection can pass")
      }),
      it("gives up on an HTTP/2 stream reset with internal_error", fn() {
        // Arrange
        use port <- edge_server.with("h2_rst")
        let request =
          edge_server.request(port) |> client.protocols(client.Http2Only)

        // Act
        let outcome = summary(classify(client.send(request)))

        // Assert
        outcome
        |> should
        |> be_equal(
          "GiveUp Stream reset (internal_error): Stream reset by server.",
        )
        |> or_fail_with("An internal error of the server is final")
      }),
    ]),
    group("step 2: timeouts", [
      it("fetch_report times out after 500 ms", fn() {
        // Act
        let result =
          fetch_report(api(), 500)
          |> result.map(fn(response) { response.status })

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(500))))
        |> or_fail_with("The slow endpoint needs 5 seconds")
      }),
      it("fetch_report gets the answer with 7 seconds", fn() {
        // Act
        let result =
          fetch_report(api(), 7000)
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"Slow response">>)))
        |> or_fail_with("7 seconds is enough for the slow endpoint")
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
      it("send_with_retry sends a GET three times", fn() {
        // Arrange
        use port <- edge_server.with("server_error")

        // Act
        let outcome = send_with_retry(edge_server.request(port), 3, 10)

        // Assert
        #(summary(outcome), edge_server.requests_received(port))
        |> should
        |> be_equal(#("TryLater HTTP 500", 3))
        |> or_fail_with("A GET should be tried three times")
      }),
      it("send_with_retry sends a POST once", fn() {
        // Arrange
        use port <- edge_server.with("server_error")
        let request = edge_server.request(port) |> client.method(http.Post)

        // Act
        let outcome = send_with_retry(request, 3, 10)

        // Assert
        #(summary(outcome), edge_server.requests_received(port))
        |> should
        |> be_equal(#("TryLater HTTP 500", 1))
        |> or_fail_with("A POST should be sent once")
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
