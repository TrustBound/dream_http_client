//// Guide: Handling errors, timeouts and retries, testing
////
//// Tests classify with mock servers that answer with a failure.

import dream_http_client/client.{host, path, port, scheme, send}
import dream_mock_server/config.{Exact, MockRoute}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None}
import snippets/guide_errors_classify.{GiveUp, TryLater, classify}

pub fn tests() -> TestSuite {
  describe("classify", [
    it("tries a 503 again later", fn() {
      // Arrange
      let routes = [MockRoute("/report", Exact, None, 503, "Busy")]
      let assert Ok(mock) = server.start_with_config(19_975, routes)

      // Act
      let outcome = classify(send(report_request(19_975)))
      server.stop(mock)

      // Assert
      outcome
      |> should
      |> be_equal(TryLater(reason: "HTTP 503"))
      |> or_fail_with("A 503 should be tried later")
    }),
    it("gives up on a 404", fn() {
      // Arrange
      let routes = [MockRoute("/report", Exact, None, 404, "No such report")]
      let assert Ok(mock) = server.start_with_config(19_976, routes)

      // Act
      let outcome = classify(send(report_request(19_976)))
      server.stop(mock)

      // Assert
      outcome
      |> should
      |> be_equal(GiveUp(reason: "HTTP 404"))
      |> or_fail_with("A 404 does not change when you ask again")
    }),
    it("tries a refused connection again later", fn() {
      // Act
      let outcome = classify(send(report_request(1)))

      // Assert
      outcome
      |> should
      |> be_equal(TryLater(reason: "Connection failed: Connection refused"))
      |> or_fail_with("A refused connection can work later")
    }),
  ])
}

fn report_request(on_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(on_port)
  |> path("/report")
}
