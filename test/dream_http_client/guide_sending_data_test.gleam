//// Tests for the snippets of the sending data guide
//// (docs/guides/sending-data.md). Each test sends a snippet's request to
//// the local mock server or to an edge server that echoes the request, and
//// asserts the exact value that the guide shows.

import dream_http_client/client.{
  type HttpResponse, type SendError, Header, RequestError, Unexpected,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import gleam/http
import gleam/list
import gleam/result
import gleam/string
import snippets/guide_sending_data_create.{create_todo}
import snippets/guide_sending_data_headers.{authorized}
import snippets/guide_sending_data_responses.{explain, header_value}
import snippets/guide_sending_data_search.{search_todos}
import snippets/guide_sending_data_update.{delete_todo, mark_done, replace_todo}
import snippets/guide_sending_data_upload.{upload}

pub fn tests() -> TestSuite {
  describe("sending data guide", [
    group("steps", [
      it("step 1: create_todo posts the JSON body", fn() {
        // Act
        let answer = status_and_body(create_todo(api(), "Buy milk"))

        // Assert
        answer
        |> should
        |> be_equal(
          Ok(#(
            201,
            "{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"{\\\"title\\\":\\\"Buy milk\\\",\\\"done\\\":false}\"}",
          )),
        )
        |> or_fail_with("The mock server should echo the JSON body")
      }),
      it("step 2: replace_todo puts the JSON body", fn() {
        // Act
        let answer = status_and_body(replace_todo(api(), "Buy oat milk"))

        // Assert
        answer
        |> should
        |> be_equal(
          Ok(#(
            200,
            "{\"method\":\"PUT\",\"url\":\"/put\",\"data\":\"{\\\"title\\\":\\\"Buy oat milk\\\",\\\"done\\\":false}\"}",
          )),
        )
        |> or_fail_with("The mock server should echo the PUT body")
      }),
      it("step 2: mark_done patches the done field", fn() {
        // Act
        let answer = status_and_body(mark_done(api()))

        // Assert
        answer
        |> should
        |> be_equal(
          Ok(#(
            200,
            "{\"method\":\"PATCH\",\"url\":\"/patch\",\"data\":\"{\\\"done\\\":true}\"}",
          )),
        )
        |> or_fail_with("The mock server should echo the PATCH body")
      }),
      it("step 2: delete_todo sends a DELETE", fn() {
        // Act
        let answer = status_and_body(delete_todo(api()))

        // Assert
        answer
        |> should
        |> be_equal(Ok(#(200, "{\"method\":\"DELETE\",\"url\":\"/delete\"}")))
        |> or_fail_with("The mock server should answer the DELETE")
      }),
      it("step 3: search_todos encodes the query", fn() {
        // Act
        let answer = status_and_body(search_todos(api(), "milk & eggs", 2))

        // Assert
        answer
        |> should
        |> be_equal(
          Ok(#(
            200,
            "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"q=milk%20%26%20eggs&page=2\",\"headers\":[]}",
          )),
        )
        |> or_fail_with("The query should reach the server encoded")
      }),
      it("step 4: authorized adds the headers the server receives", fn() {
        // Arrange
        use port <- edge_server.with("echo_head")
        let request =
          edge_server.request(port)
          |> client.path("/items")
          |> authorized("test-token-123")

        // Act
        let head = received_head(request)

        // Assert
        head
        |> should
        |> be_equal(
          Ok([
            "GET /items HTTP/1.1", "content-length: 0",
            "user-agent: greeter/1.0", "authorization: Bearer test-token-123",
            "accept-encoding: gzip, deflate",
          ]),
        )
        |> or_fail_with("The server should receive both headers")
      }),
      it("step 5: upload sends bytes that are not text", fn() {
        // Arrange
        use port <- edge_server.with("echo_body")
        let bytes = <<137, 80, 78, 71, 0, 255>>

        // Act
        let echoed = upload(edge_server.request(port), bytes)

        // Assert
        echoed
        |> should
        |> be_equal(Ok(<<137, 80, 78, 71, 0, 255>>))
        |> or_fail_with("The server should get the exact bytes")
      }),
      it("step 6: header_value reads a header in lower case", fn() {
        // Arrange
        use port <- edge_server.with("echo_head")

        // Act
        let value =
          client.send(edge_server.request(port))
          |> result.replace_error(Nil)
          |> result.try(header_value(_, "x-request-id"))

        // Assert
        value
        |> should
        |> be_equal(Ok("req-42"))
        |> or_fail_with("The server sent X-Request-Id: req-42")
      }),
      it("step 6: explain reads the body of a refusal", fn() {
        // Act
        let message = explain(client.send(mock_server.get("/status/422")))

        // Assert
        message
        |> should
        |> be_equal("Refused with 422: {\"status\":422}")
        |> or_fail_with("explain should show the status and the body")
      }),
      it("step 6: explain describes a request with no answer", fn() {
        // Act
        let message = explain(client.send(mock_server.closed_port("/")))

        // Assert
        message
        |> should
        |> be_equal("No answer: Connection failed: Connection refused")
        |> or_fail_with("explain should describe the transport error")
      }),
      it("step 6: explain reports a success", fn() {
        // Act
        let message = explain(client.send(mock_server.get("/text")))

        // Assert
        message
        |> should
        |> be_equal("Done: 200")
        |> or_fail_with("explain should show the status of a success")
      }),
    ]),
    group("failures and pitfalls", [
      it("text bytes that are not UTF-8 get a 400 from /post", fn() {
        // Arrange
        let request =
          mock_server.request(http.Post, "/post")
          |> client.body_bits(<<255, 0>>)

        // Act
        let message = explain(client.send(request))

        // Assert
        message
        |> should
        |> be_equal(
          "Refused with 400: {\"error\":\"Request body is not UTF-8 text\"}",
        )
        |> or_fail_with("The mock server refuses a body that is not text")
      }),
      it("a raw space in the query is not a valid URI", fn() {
        // Arrange
        let request = mock_server.get("/get") |> client.query("q=milk and eggs")

        // Act
        let result = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(Unexpected("invalid_uri"))))
        |> or_fail_with("A raw space should fail")
      }),
      it("the client sends no content-type of its own", fn() {
        // Arrange
        let request =
          mock_server.request(http.Post, "/content-type")
          |> client.body("{}")

        // Act
        let answer = status_and_body(client.send(request))

        // Assert
        answer
        |> should
        |> be_equal(Ok(#(200, "")))
        |> or_fail_with("The server should see no content-type")
      }),
      it("a header name in capitals finds nothing", fn() {
        // Arrange
        use port <- edge_server.with("echo_head")

        // Act
        let value =
          client.send(edge_server.request(port))
          |> result.replace_error(Nil)
          |> result.try(header_value(_, "X-Request-Id"))

        // Assert
        value
        |> should
        |> be_equal(Error(Nil))
        |> or_fail_with("Names come in lower case")
      }),
      it("headers replaces the headers that add_header added", fn() {
        // Arrange
        let request =
          client.new()
          |> client.add_header("authorization", "Bearer test-token-123")
          |> client.headers([Header("accept", "application/json")])

        // Act
        let headers = client.get_headers(request)

        // Assert
        headers
        |> should
        |> be_equal([Header("accept", "application/json")])
        |> or_fail_with("headers should replace the list")
      }),
      it("the client asks for gzip and decompresses it", fn() {
        // Act
        let answer = status_and_body(client.send(mock_server.get("/gzip")))

        // Assert
        answer
        |> should
        |> be_equal(Ok(#(200, "Hello, World!")))
        |> or_fail_with("The gzip body should arrive decompressed")
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

fn status_and_body(
  result: Result(HttpResponse, SendError),
) -> Result(#(Int, String), Nil) {
  use response <- result.try(result.replace_error(result, Nil))
  use text <- result.map(client.body_text(response))
  #(response.status, text)
}

/// The lines of the request head that the echo_head server received,
/// without the host line, whose port changes from run to run.
fn received_head(request: client.ClientRequest) -> Result(List(String), Nil) {
  use response <- result.try(client.send(request) |> result.replace_error(Nil))
  use text <- result.map(client.body_text(response))
  string.split(text, "\r\n")
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "host: ") })
}
