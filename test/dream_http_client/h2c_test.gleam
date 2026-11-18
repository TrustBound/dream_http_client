//// HTTP/2 over cleartext (h2c) against the local mock server.

import dream_http_client/client.{Header, Http1Only, Http2Only}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("h2c", [
    group("client.send", [
      it("send to /text returns its body", fn() {
        // Arrange
        let request = mock_server.get("/text") |> client.protocols(Http2Only)

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, "Hello, World!")))
        |> or_fail_with("h2c should route to /text")
      }),
      it("send to /json returns its body", fn() {
        // Arrange
        let request = mock_server.get("/json") |> client.protocols(Http2Only)

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(#(200, "{\"message\":\"Hello, World!\",\"success\":true}")),
        )
        |> or_fail_with("h2c should route to /json")
      }),
      it("send to /status/500 returns a ResponseError", fn() {
        // Arrange
        let request =
          mock_server.get("/status/500") |> client.protocols(Http2Only)

        // Act
        let value =
          client.send(request)
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) -> Ok(response.status)
              client.RequestError(transport) -> Error(transport)
            }
          })

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(500)))
        |> or_fail_with("h2c should surface the 500")
      }),
      it("send POST with a body returns 201", fn() {
        // Arrange
        let request =
          mock_server.request(http.Post, "/post")
          |> client.protocols(Http2Only)
          |> client.body("{\"key\":\"value\"}")
          |> client.headers([Header("Content-Type", "application/json")])

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(#(
            201,
            "{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"{\\\"key\\\":\\\"value\\\"}\"}",
          )),
        )
        |> or_fail_with("h2c POST should echo the body")
      }),
      it("send decompresses a gzip body", fn() {
        // Arrange
        let request = mock_server.get("/gzip") |> client.protocols(Http2Only)

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, "Hello, World!")))
        |> or_fail_with("h2c should decompress gzip")
      }),
      it("send returns the response headers", fn() {
        // Arrange
        let request = mock_server.get("/text") |> client.protocols(Http2Only)

        // Act
        let value =
          client.send(request)
          |> result.map(fn(response) {
            list.find(response.headers, fn(header) {
              string.lowercase(header.name) == "content-type"
            })
            |> result.map(fn(header) { header.value })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok(Ok("text/plain; charset=utf-8")))
        |> or_fail_with("h2c should return the Content-Type header")
      }),
      it("three concurrent sends all return the body", fn() {
        // Arrange
        let results = process.new_subject()

        // Act
        list.each([1, 2, 3], fn(_) {
          process.spawn_unlinked(fn() {
            let request =
              mock_server.get("/text") |> client.protocols(Http2Only)
            process.send(
              results,
              client.send(request) |> result.map(fn(r) { #(r.status, r.body) }),
            )
          })
        })
        let value = mailbox.take(results, 3, 10_000)

        // Assert
        value
        |> should
        |> be_equal([
          Ok(#(200, "Hello, World!")),
          Ok(#(200, "Hello, World!")),
          Ok(#(200, "Hello, World!")),
        ])
        |> or_fail_with("All three h2c sends should succeed")
      }),
      it("HTTP/1.1 still works after an h2c request", fn() {
        // Arrange
        let assert Ok(_h2c) =
          client.send(mock_server.get("/text") |> client.protocols(Http2Only))
        let request = mock_server.get("/text")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, "Hello, World!")))
        |> or_fail_with("HTTP/1.1 should work after h2c")
      }),
    ]),
    group("client.stream_yielder", [
      it("stream_yielder gets every chunk of /stream/fast", fn() {
        // Arrange
        let request =
          mock_server.get("/stream/fast") |> client.protocols(Http2Only)

        // Act
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("h2c stream should yield all chunks")
      }),
      it("stream_yielder decompresses gzip chunks", fn() {
        // Arrange
        let request =
          mock_server.get("/stream/gzip") |> client.protocols(Http2Only)

        // Act
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n">>))
        |> or_fail_with("h2c stream should decompress gzip")
      }),
      it("Http1Only stream_yielder gets every chunk", fn() {
        // Arrange
        let request =
          mock_server.get("/stream/fast") |> client.protocols(Http1Only)

        // Act
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("Http1Only stream should yield all chunks")
      }),
      it("Http1Only send returns the body", fn() {
        // Arrange
        let request = mock_server.get("/text") |> client.protocols(Http1Only)

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, "Hello, World!")))
        |> or_fail_with("Http1Only should return the body")
      }),
    ]),
    group("client.start_stream", [
      it("start_stream delivers every chunk", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/fast")
          |> client.protocols(Http2Only)
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })
        let assert Ok(_handle) = client.start_stream(request)

        // Act
        let end = process.receive(ended, 10_000)
        let value = #(end, mailbox.drain_bits(chunks))

        // Assert
        value
        |> should
        |> be_equal(
          #(Ok(True), <<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("h2c start_stream should deliver every chunk")
      }),
      it("start_stream passes the headers to on_stream_start", fn() {
        // Arrange
        let started = process.new_subject()
        let request =
          mock_server.get("/stream/fast")
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(headers) {
            process.send(started, headers)
          })

        // Act
        let assert Ok(handle) = client.start_stream(request)
        let value =
          process.receive(started, 10_000)
          |> result.try(fn(headers) {
            list.find(headers, fn(header) {
              string.lowercase(header.name) == "content-type"
            })
          })
          |> result.map(fn(header) { header.value })
        client.cancel_stream_handle(handle)

        // Assert
        value
        |> should
        |> be_equal(Ok("text/plain"))
        |> or_fail_with("on_stream_start should get the Content-Type header")
      }),
    ]),
  ])
}
