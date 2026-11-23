//// Auto-redirect integration tests
////
//// Tests the shim's manual redirect-following logic against live mock server
//// endpoints. Gun does not auto-redirect natively, so the shim implements
//// redirect following for 301, 302, 303, 307, and 308 status codes.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import gleam/bytes_tree
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("auto redirect", [
    group("client.send", [
      it("follows a 301 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/301")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A 301 should be followed to /text")
      }),
      it("follows a 302 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/302")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A 302 should be followed to /text")
      }),
      it("follows a 303 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/303")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A 303 should be followed to /text")
      }),
      it("follows a 307 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/307")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A 307 should be followed to /text")
      }),
      it("follows a 308 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/308")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A 308 should be followed to /text")
      }),
      it("returns the 3xx response when auto_redirect is False", fn() {
        // Arrange
        let request =
          mock_server.get("/redirect/301") |> client.auto_redirect(False)

        // Act
        let response =
          client.send(request)
          |> result.map(fn(r) {
            #(
              r.status,
              list.find(r.headers, fn(h) {
                string.lowercase(h.name) == "location"
              })
                |> result.map(fn(h) { h.value }),
            )
          })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(301, Ok("/text"))))
        |> or_fail_with("The 301 and its Location header should come back")
      }),
      it("follows a chain of two redirects", fn() {
        // Arrange
        let request = mock_server.get("/redirect/chain")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("Both redirects should be followed")
      }),
      it("follows an absolute Location URL", fn() {
        // Arrange
        let request = mock_server.get("/redirect/absolute")

        // Act
        let response =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        response
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("An absolute Location should be followed")
      }),
    ]),
    group("client.stream_yielder", [
      it("follows a 301 to /text", fn() {
        // Arrange
        let request = mock_server.get("/redirect/301")

        // Act
        let body =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        body
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("The stream should yield the body of /text")
      }),
      it("follows a chain of two redirects", fn() {
        // Arrange
        let request = mock_server.get("/redirect/chain")

        // Act
        let body =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        body
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("The stream should yield the body of /text")
      }),
    ]),
    group("client.start_stream", [
      it("follows a 301 to /text", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/redirect/301")
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
        let assert Ok(_handle) = client.start_stream(request)

        // Act
        let end = process.receive(ended, 10_000)
        let body = mailbox.drain_bits(chunks)

        // Assert
        #(end, body)
        |> should
        |> be_equal(#(Ok(Nil), <<"Hello, World!">>))
        |> or_fail_with("The callbacks should get the body of /text")
      }),
    ]),
  ])
}
