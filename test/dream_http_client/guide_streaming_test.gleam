//// Tests for the snippets of the streaming guide
//// (docs/guides/streaming.md). Each test runs a snippet against the local
//// mock server and asserts the exact value or output that the guide shows.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import fixtures/output
import fixtures/temp_directory
import gleam/result
import simplifile
import snippets/guide_streaming_callbacks
import snippets/guide_streaming_cancel
import snippets/guide_streaming_failures.{Broken, Refused, Stalled, Unreachable}
import snippets/guide_streaming_json_lines
import snippets/guide_streaming_long_timeout
import snippets/guide_streaming_print_chunks

const fast_body = <<
  "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
  "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
>>

pub fn tests() -> TestSuite {
  describe("streaming guide", [
    it("step 1: print_chunks prints ten chunks with their sizes", fn() {
      // Act
      let printed = output.capture(guide_streaming_print_chunks.print_chunks)

      // Assert
      printed
      |> should
      |> be_equal(#(
        Ok(10),
        "[8 bytes] Chunk 1\n[8 bytes] Chunk 2\n[8 bytes] Chunk 3\n"
          <> "[8 bytes] Chunk 4\n[8 bytes] Chunk 5\n[8 bytes] Chunk 6\n"
          <> "[8 bytes] Chunk 7\n[8 bytes] Chunk 8\n[8 bytes] Chunk 9\n"
          <> "[9 bytes] Chunk 10\n",
      ))
      |> or_fail_with("print_chunks should print each chunk of /stream/fast")
    }),
    it("step 2: complete_lines keeps the start of a split line", fn() {
      // Act
      let split =
        guide_streaming_json_lines.complete_lines(<<
          "{\"message\":\"first\"}\n{\"mess",
        >>)

      // Assert
      split
      |> should
      |> be_equal(#([<<"{\"message\":\"first\"}">>], <<"{\"mess">>))
      |> or_fail_with("The bytes after the last newline should wait")
    }),
    it("step 2: complete_lines finishes the line with the next chunk", fn() {
      // Act
      let split =
        guide_streaming_json_lines.complete_lines(<<
          "{\"mess", "age\":\"second\"}\n",
        >>)

      // Assert
      split
      |> should
      |> be_equal(#([<<"{\"message\":\"second\"}">>], <<>>))
      |> or_fail_with("The joined bytes should make one complete line")
    }),
    it("step 2: print_mock_events prints the five messages", fn() {
      // Act
      let printed = output.capture(guide_streaming_json_lines.print_mock_events)

      // Assert
      printed
      |> should
      |> be_equal(#(
        Ok(5),
        "JSON event 1\nJSON event 2\nJSON event 3\nJSON event 4\nJSON event 5\n",
      ))
      |> or_fail_with("print_mock_events should print each message")
    }),
    it("step 3: count_bytes counts a whole stream", fn() {
      // Act
      let counted =
        guide_streaming_failures.count_bytes(mock_server.get("/stream/fast"))

      // Assert
      counted
      |> should
      |> be_equal(Ok(81))
      |> or_fail_with("/stream/fast has 81 bytes")
    }),
    it("step 3: count_bytes reports an error status as Refused", fn() {
      // Act
      let counted =
        guide_streaming_failures.count_bytes(mock_server.get("/stream/error"))

      // Assert
      counted
      |> should
      |> be_equal(
        Error(
          Refused(status: 500, body: <<
            "Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
          >>),
        ),
      )
      |> or_fail_with("/stream/error answers 500 with a body")
    }),
    it("step 3: count_bytes reports a dropped connection as Broken", fn() {
      // Act
      let counted =
        guide_streaming_failures.count_bytes(mock_server.get("/stream/drop"))

      // Assert
      counted
      |> should
      |> be_equal(
        Error(Broken(received: 26, reason: "Remote closed connection")),
      )
      |> or_fail_with("/stream/drop closes the connection after 26 bytes")
    }),
    it("step 3: count_bytes reports a silent server as Stalled", fn() {
      // Arrange
      let request =
        mock_server.get("/stream/slow")
        |> client.timeout(500)

      // Act
      let counted = guide_streaming_failures.count_bytes(request)

      // Assert
      counted
      |> should
      |> be_equal(Error(Stalled(received: 0, waited_ms: 500)))
      |> or_fail_with("/stream/slow waits 2 seconds before its first chunk")
    }),
    it("step 3: count_bytes reports a refused connection as Unreachable", fn() {
      // Arrange
      let request =
        mock_server.get("/stream/fast")
        |> client.port(1)

      // Act
      let counted = guide_streaming_failures.count_bytes(request)

      // Assert
      counted
      |> should
      |> be_equal(Error(Unreachable(reason: "Connection refused")))
      |> or_fail_with("Nothing listens on port 1")
    }),
    it("step 4: download_to_file writes the whole stream to the file", fn() {
      // Arrange
      let file_path = temp_directory.path("guide_streaming_download.txt")
      let assert Ok(Nil) = simplifile.create_directory_all(temp_directory.root)

      // Act
      let written =
        guide_streaming_callbacks.download_to_file(file_path)
        |> result.try(fn(_downloaded) {
          simplifile.read_bits(file_path)
          |> result.map_error(simplifile.describe_error)
        })

      // Assert
      written
      |> should
      |> be_equal(Ok(fast_body))
      |> or_fail_with("The file should hold the whole body of /stream/fast")
    }),
    it("step 5: first_chunk returns the first chunk and stops", fn() {
      // Act
      let first =
        guide_streaming_cancel.first_chunk(mock_server.get("/stream/slow"))

      // Assert
      first
      |> should
      |> be_equal(Ok(<<"Chunk 1\n">>))
      |> or_fail_with("The first chunk of /stream/slow is Chunk 1")
    }),
    it("timeouts: a 3-second timeout reads a 10-second stream", fn() {
      // Act
      let counted = guide_streaming_long_timeout.count_slow_chunks()

      // Assert
      counted
      |> should
      |> be_equal(Ok(5))
      |> or_fail_with("All five chunks of /stream/slow should arrive")
    }),
  ])
}
