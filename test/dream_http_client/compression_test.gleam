//// Content-Encoding handling: gzip, deflate, identity and unknown
//// encodings, and the Accept-Encoding header, for all three execution modes.

import dream_http_client/client.{Header}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import gleam/bytes_tree
import gleam/erlang/process
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("compression", [
    group("client.send", [
      it("decompresses a gzip body", fn() {
        // Arrange
        let request = mock_server.get("/gzip")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("gzip should be decompressed")
      }),
      it("decompresses a deflate body", fn() {
        // Arrange
        let request = mock_server.get("/deflate")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("deflate should be decompressed")
      }),
      it("passes an identity body through", fn() {
        // Arrange
        let request = mock_server.get("/identity")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("identity should pass through")
      }),
      it("passes a body with an unknown encoding through", fn() {
        // Arrange
        let request = mock_server.get("/unknown-encoding")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"raw-uncompressed-bytes">>)))
        |> or_fail_with("An unknown encoding should pass through")
      }),
      it("returns the raw body when gzip data is corrupted", fn() {
        // Arrange
        let request = mock_server.get("/corrupted-gzip")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"this is not valid gzip data at all">>)))
        |> or_fail_with("Corrupted gzip should come back as the raw body")
      }),
      it("sends Accept-Encoding gzip, deflate by default", fn() {
        // Arrange
        let request = mock_server.get("/echo-accept-encoding")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"gzip, deflate">>)))
        |> or_fail_with("The default Accept-Encoding should be sent")
      }),
      it("keeps the Accept-Encoding of the caller", fn() {
        // Arrange
        let request =
          mock_server.get("/echo-accept-encoding")
          |> client.headers([Header("Accept-Encoding", "zstd")])

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"zstd">>)))
        |> or_fail_with("The caller Accept-Encoding should be kept")
      }),
    ]),
    group("client.start_stream", [
      it("decompresses gzip chunks", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/gzip")
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
          #(Ok(True), <<"Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n">>),
        )
        |> or_fail_with("start_stream decompresses gzip chunks")
      }),
      it("decompresses deflate chunks", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/deflate")
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
          #(Ok(True), <<"Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n">>),
        )
        |> or_fail_with("start_stream decompresses deflate chunks")
      }),
      it("passes chunks with an unknown encoding through", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/unknown-encoding")
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
        |> be_equal(#(Ok(True), <<"Raw 1\nRaw 2\nRaw 3\nRaw 4\nRaw 5\n">>))
        |> or_fail_with(
          "start_stream passes chunks with an unknown encoding through",
        )
      }),
      it("sends Accept-Encoding gzip, deflate by default", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/echo-accept-encoding")
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
        |> be_equal(#(Ok(True), <<"gzip, deflate">>))
        |> or_fail_with("The default Accept-Encoding should be sent")
      }),
      it("keeps the Accept-Encoding of the caller", fn() {
        // Arrange
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/echo-accept-encoding")
          |> client.headers([Header("Accept-Encoding", "zstd")])
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
        |> be_equal(#(Ok(True), <<"zstd">>))
        |> or_fail_with("The caller Accept-Encoding should be kept")
      }),
      it("ends the stream process after a gzip stream", fn() {
        // Arrange
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/gzip")
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
        let assert Ok(handle) = client.start_stream(request)
        let assert Ok(True) = process.receive(ended, 10_000)

        // Act
        client.await_stream(handle)
        let value = client.is_stream_active(handle)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("The gzip stream process should end")
      }),
      it("ends the stream process after an error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          mock_server.get("/status/500")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })
        let assert Ok(handle) = client.start_stream(request)
        let assert Ok(_failure) = process.receive(errors, 5000)

        // Act
        client.await_stream(handle)
        let value = client.is_stream_active(handle)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("The stream process should end after an error")
      }),
    ]),
    group("client.stream_yielder", [
      it("decompresses gzip chunks", fn() {
        // Arrange
        let request = mock_server.get("/stream/gzip")

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
        |> or_fail_with("gzip chunks should be decompressed")
      }),
      it("decompresses deflate chunks", fn() {
        // Arrange
        let request = mock_server.get("/stream/deflate")

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
        |> or_fail_with("deflate chunks should be decompressed")
      }),
      it("passes chunks with an unknown encoding through", fn() {
        // Arrange
        let request = mock_server.get("/stream/unknown-encoding")

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
        |> be_equal(Ok(<<"Raw 1\nRaw 2\nRaw 3\nRaw 4\nRaw 5\n">>))
        |> or_fail_with("Unknown encoding chunks should pass through")
      }),
      it("reads a stream with no encoding", fn() {
        // Arrange
        let request = mock_server.get("/stream/fast")

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
        |> or_fail_with("A plain stream should be read")
      }),
      it("sends Accept-Encoding gzip, deflate by default", fn() {
        // Arrange
        let request = mock_server.get("/echo-accept-encoding")

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
        |> be_equal(Ok(<<"gzip, deflate">>))
        |> or_fail_with("The default Accept-Encoding should be sent")
      }),
      it("keeps the Accept-Encoding of the caller", fn() {
        // Arrange
        let request =
          mock_server.get("/echo-accept-encoding")
          |> client.headers([Header("Accept-Encoding", "zstd")])

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
        |> be_equal(Ok(<<"zstd">>))
        |> or_fail_with("The caller Accept-Encoding should be kept")
      }),
    ]),
  ])
}
