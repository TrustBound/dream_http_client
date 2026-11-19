//// Empty body regression tests
////
//// Verifies that PUT, POST, PATCH, GET, and DELETE all complete successfully
//// when sent with no request body. Previously, PUT/POST/PATCH hung forever
//// due to gun's inconsistent method-specific dispatch for empty bodies.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import gleam/http
import gleam/result

pub fn tests() -> TestSuite(Nil) {
  describe("send with an empty body", [
    it("completes a PUT with status 200", fn() {
      // Arrange
      let request =
        mock_server.request(http.Put, "/put") |> client.timeout(5000)

      // Act
      let status = client.send(request) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("PUT with no body should return 200")
    }),
    it("completes a POST with status 201", fn() {
      // Arrange
      let request =
        mock_server.request(http.Post, "/post") |> client.timeout(5000)

      // Act
      let status = client.send(request) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(201))
      |> or_fail_with("POST with no body should return 201")
    }),
    it("completes a PATCH with status 200", fn() {
      // Arrange
      let request =
        mock_server.request(http.Patch, "/patch") |> client.timeout(5000)

      // Act
      let status = client.send(request) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("PATCH with no body should return 200")
    }),
    it("completes a GET with status 200", fn() {
      // Arrange
      let request =
        mock_server.request(http.Get, "/text") |> client.timeout(5000)

      // Act
      let status = client.send(request) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("GET with no body should return 200")
    }),
    it("completes a DELETE with status 200", fn() {
      // Arrange
      let request =
        mock_server.request(http.Delete, "/delete") |> client.timeout(5000)

      // Act
      let status = client.send(request) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("DELETE with no body should return 200")
    }),
  ])
}
