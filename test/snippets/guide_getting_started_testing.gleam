//// Guide: Getting started, testing
////
//// Tests fetch_greeting against a mock server with its built-in
//// endpoints, and against mock servers that answer with a failure.

import dream_http_client/client.{port}
import dream_mock_server/config.{Exact, MockRoute}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/json
import gleam/option.{None}
import snippets/guide_getting_started_api_client.{
  BadBody, BadStatus, Greeting, fetch_greeting, local_api,
}

pub fn tests() -> TestSuite {
  describe("fetch_greeting", [
    it("decodes the greeting of the API", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_971)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_971))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Ok(Greeting(message: "Hello, World!", success: True)))
      |> or_fail_with("Expected the greeting of the mock server")
    }),
    it("reports the status of an API that is down", fn() {
      // Arrange
      let routes = [MockRoute("/json", Exact, None, 503, "Down for repairs")]
      let assert Ok(mock) = server.start_with_config(19_972, routes)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_972))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Error(BadStatus(status: 503)))
      |> or_fail_with("Expected BadStatus(503)")
    }),
    it("reports a body that is not JSON", fn() {
      // Arrange
      let routes = [MockRoute("/json", Exact, None, 200, "<html></html>")]
      let assert Ok(mock) = server.start_with_config(19_973, routes)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_973))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Error(BadBody(error: json.UnexpectedByte("0x3C"))))
      |> or_fail_with("Expected BadBody for an HTML body")
    }),
  ])
}
