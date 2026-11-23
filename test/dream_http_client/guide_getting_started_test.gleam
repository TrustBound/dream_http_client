//// Tests for the snippets of the getting started guide
//// (docs/guides/getting-started.md). Each test runs a snippet against the
//// local mock server and asserts the exact value or output that the guide
//// shows.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import fixtures/output
import gleam/http
import gleam/result
import snippets/guide_getting_started_api_client.{
  BadStatus, Greeting, Unreachable, describe_api_error, fetch_greeting,
  local_api,
}
import snippets/guide_getting_started_first_request
import snippets/guide_getting_started_main

pub fn tests() -> TestSuite {
  describe("getting started guide", [
    it("step 1: main prints the status and the body", fn() {
      // Act
      let printed = output.capture(guide_getting_started_first_request.main)

      // Assert
      printed
      |> should
      |> be_equal(#(Nil, "Status: 200\nBody: Hello, World!\n"))
      |> or_fail_with("main should print the answer of /text")
    }),
    it("step 2: fetch_greeting decodes the greeting", fn() {
      // Act
      let greeting = fetch_greeting(local_api())

      // Assert
      greeting
      |> should
      |> be_equal(Ok(Greeting(message: "Hello, World!", success: True)))
      |> or_fail_with("fetch_greeting should decode /json")
    }),
    it("step 3: fetch_greeting reports a port where nothing listens", fn() {
      // Act
      let greeting = fetch_greeting(local_api() |> client.port(1))

      // Assert
      greeting
      |> should
      |> be_equal(
        Error(Unreachable(error: client.ConnectFailed("Connection refused"))),
      )
      |> or_fail_with("A refused connection should be Unreachable")
    }),
    it("step 3: describe_api_error describes an unreachable API", fn() {
      // Act
      let message =
        describe_api_error(
          Unreachable(client.ConnectFailed("Connection refused")),
        )

      // Assert
      message
      |> should
      |> be_equal("Cannot reach the API: Connection failed: Connection refused")
      |> or_fail_with("The message should name the transport error")
    }),
    it("step 3: describe_api_error describes a bad status", fn() {
      // Act
      let message = describe_api_error(BadStatus(status: 503))

      // Assert
      message
      |> should
      |> be_equal("The API answered 503")
      |> or_fail_with("The message should name the status")
    }),
    it("step 4: main prints the greeting", fn() {
      // Act
      let printed = output.capture(guide_getting_started_main.main)

      // Assert
      printed
      |> should
      |> be_equal(#(Nil, "Hello, World!\n"))
      |> or_fail_with("main should print the message of the greeting")
    }),
    it("pitfall: HTTPS to a plain HTTP server fails with closed", fn() {
      // Arrange
      let request =
        client.new()
        |> client.host("localhost")
        |> client.port(mock_server.port())
        |> client.path("/text")

      // Act
      let result =
        client.send(request) |> result.map(fn(response) { response.status })

      // Assert
      result
      |> should
      |> be_equal(Error(client.RequestError(client.ConnectFailed("closed"))))
      |> or_fail_with("The default scheme is HTTPS")
    }),
    it("pitfall: a URL in host fails the DNS lookup", fn() {
      // Arrange
      let request =
        client.new()
        |> client.host("http://localhost:9876")
        |> client.path("/text")

      // Act
      let result =
        client.send(request) |> result.map(fn(response) { response.status })

      // Assert
      result
      |> should
      |> be_equal(
        Error(
          client.RequestError(client.ConnectFailed(
            "DNS resolution failed (NXDOMAIN)",
          )),
        ),
      )
      |> or_fail_with("host takes only a host name")
    }),
    it("pitfall: without a port, plain HTTP goes to port 80", fn() {
      // Arrange
      let request =
        client.new()
        |> client.scheme(http.Http)
        |> client.host("localhost")
        |> client.path("/text")

      // Act
      let result =
        client.send(request) |> result.map(fn(response) { response.status })

      // Assert
      result
      |> should
      |> be_equal(
        Error(client.RequestError(client.ConnectFailed("Connection refused"))),
      )
      |> or_fail_with("Nothing listens on port 80")
    }),
    it("pitfall: a 3xx with redirects turned off is Ok", fn() {
      // Arrange
      let request =
        mock_server.get("/redirect/302") |> client.auto_redirect(False)

      // Act
      let result =
        client.send(request) |> result.map(fn(response) { response.status })

      // Assert
      result
      |> should
      |> be_equal(Ok(302))
      |> or_fail_with("send returns Ok for a status below 400")
    }),
  ])
}
