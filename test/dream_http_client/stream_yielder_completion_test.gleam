//// Regression tests for stream_yielder completion behavior
////
//// These tests ensure that stream_yielder correctly handles normal stream
//// completion vs errors. Previously, the yielder would yield
//// `Error("Stream finished")` for normal completion, which was incorrect.
////
//// Correct behavior:
//// - Normal completion: yielder returns Done (no more items)
//// - Actual errors: yielder yields Error(reason) then Done

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import gleam/bytes_tree
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("client.stream_yielder completion", [
    it("yields every chunk of a fast stream and no error", fn() {
      // Arrange
      let request = mock_server.get("/stream/fast")

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
      |> be_equal(
        Ok(<<
          "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
          "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
        >>),
      )
      |> or_fail_with("A completed stream should yield only Ok chunks")
    }),
    it("ends with an Ok chunk, not an error", fn() {
      // Arrange
      let request = mock_server.get("/stream/fast")

      // Act
      let last_is_ok =
        client.stream_yielder(request)
        |> yielder.to_list
        |> list.last
        |> result.map(result.is_ok)

      // Assert
      last_is_ok
      |> should
      |> be_equal(Ok(True))
      |> or_fail_with("The last item of a completed stream should be Ok")
    }),
    it("yields every chunk of a slow stream and no error", fn() {
      // Arrange
      let request = mock_server.get("/stream/slow")

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
      |> be_equal(Ok(<<"Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n">>))
      |> or_fail_with("A slow stream should yield only Ok chunks")
    }),
  ])
}
