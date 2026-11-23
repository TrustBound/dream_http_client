//// Guide: Sending data to an API, testing
////
//// Tests create_todo and search_todos against their own mock server, with
//// the body that the server echoes.

import dream_http_client/client.{host, port, scheme}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/result
import snippets/guide_sending_data_create.{create_todo}
import snippets/guide_sending_data_search.{search_todos}

pub fn tests() -> TestSuite {
  describe("to-do API", [
    it("posts the new to-do as JSON", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_974)

      // Act
      let answer =
        create_todo(test_api(19_974), "Buy milk")
        |> result.map(fn(response) { #(response.status, response.body) })
      server.stop(mock)

      // Assert
      answer
      |> should
      |> be_equal(
        Ok(
          #(201, <<
            "{\"method\":\"POST\",\"url\":\"/post\",",
            "\"data\":\"{\\\"title\\\":\\\"Buy milk\\\",\\\"done\\\":false}\"}",
          >>),
        ),
      )
      |> or_fail_with("Expected the echo of the JSON body")
    }),
    it("encodes the search words in the query", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_977)

      // Act
      let answer =
        search_todos(test_api(19_977), "milk & eggs", 2)
        |> result.map(fn(response) { response.body })
      server.stop(mock)

      // Assert
      answer
      |> should
      |> be_equal(
        Ok(<<
          "{\"method\":\"GET\",\"url\":\"/get\",",
          "\"query\":\"q=milk%20%26%20eggs&page=2\",\"headers\":[]}",
        >>),
      )
      |> or_fail_with("Expected the encoded query")
    }),
  ])
}

fn test_api(mock_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
}
