//// Tests for the snippets of the streaming guide
//// (docs/guides/streaming.md). Each test runs a snippet against the local
//// mock server and asserts the exact value or output that the guide shows.
//// The output that the guide shows in a `text` block is a file in
//// `test/outputs/`, and the tests compare it with the real output.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import fixtures/output
import fixtures/output_file
import fixtures/shown
import fixtures/temp_directory
import gleam/int
import gleam/result
import gleam/string
import simplifile
import snippets/guide_streaming_callbacks
import snippets/guide_streaming_cancel
import snippets/guide_streaming_failures.{
  type DownloadError, Broken, Refused, Stalled, Unreachable,
}
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
      |> be_equal(#(Ok(10), output_file.read("guide_streaming_print_chunks")))
      |> or_fail_with("print_chunks should print each chunk of /stream/fast")
    }),
    it("step 2: complete_lines keeps a split line for the next chunk", fn() {
      // Act
      let lines = [
        "complete_lines(<<\"{\\\"message\\\":\\\"first\\\"}\\n{\\\"mess\">>)",
        "  -> "
          <> shown_split(
          guide_streaming_json_lines.complete_lines(<<
            "{\"message\":\"first\"}\n{\"mess",
          >>),
        ),
        "",
        "complete_lines(<<\"{\\\"mess\", \"age\\\":\\\"second\\\"}\\n\">>)",
        "  -> "
          <> shown_split(
          guide_streaming_json_lines.complete_lines(<<
            "{\"mess", "age\":\"second\"}\n",
          >>),
        ),
      ]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_streaming_complete_lines"))
      |> or_fail_with(
        "The bytes after the last newline wait for the next chunk",
      )
    }),
    it("step 2: print_mock_events prints the five messages", fn() {
      // Act
      let printed = output.capture(guide_streaming_json_lines.print_mock_events)

      // Assert
      printed
      |> should
      |> be_equal(#(Ok(5), output_file.read("guide_streaming_json_events")))
      |> or_fail_with("print_mock_events should print each message")
    }),
    it("step 3: count_bytes for each mock endpoint", fn() {
      // Arrange
      let count = guide_streaming_failures.count_bytes

      // Act
      let lines = [
        "/stream/fast                     -> "
          <> shown_count(count(mock_server.get("/stream/fast"))),
        "/stream/error                    -> "
          <> shown_count(count(mock_server.get("/stream/error"))),
        "/stream/drop                     -> "
          <> shown_count(count(mock_server.get("/stream/drop"))),
        "/stream/slow with timeout(500)   -> "
          <> shown_count(count(
          mock_server.get("/stream/slow") |> client.timeout(500),
        )),
        "port 1, where nothing listens    -> "
          <> shown_count(count(
          mock_server.get("/stream/fast") |> client.port(1),
        )),
      ]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_streaming_failures"))
      |> or_fail_with("Each failure is its own case of DownloadError")
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

/// The result of `complete_lines`, with its bit arrays as Gleam code
/// writes them.
fn shown_split(split: #(List(BitArray), BitArray)) -> String {
  "#(" <> shown.bits_list(split.0) <> ", " <> shown.bits(split.1) <> ")"
}

/// The result of `count_bytes` with the names of the fields, as the guide
/// shows it.
fn shown_count(counted: Result(Int, DownloadError)) -> String {
  case counted {
    Ok(bytes) -> "Ok(" <> int.to_string(bytes) <> ")"
    Error(error) -> "Error(" <> shown_count_error(error) <> ")"
  }
}

fn shown_count_error(error: DownloadError) -> String {
  case error {
    Refused(status:, body:) ->
      "Refused(status: "
      <> int.to_string(status)
      <> ", body: "
      <> shown.bits(body)
      <> ")"
    Broken(received:, reason:) ->
      "Broken(received: "
      <> int.to_string(received)
      <> ", reason: "
      <> string.inspect(reason)
      <> ")"
    Stalled(received:, waited_ms:) ->
      "Stalled(received: "
      <> int.to_string(received)
      <> ", waited_ms: "
      <> int.to_string(waited_ms)
      <> ")"
    Unreachable(reason:) ->
      "Unreachable(reason: " <> string.inspect(reason) <> ")"
  }
}
