//// Tests for the snippets that the doc comments and the release notes show
//// and that no guide test runs.
////
//// The requests go to dream_mock_server, which the test main starts on
//// localhost:9876.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/result
import snippets/blocking_send
import snippets/protocols_config
import snippets/stream_messages_basic
import snippets/stream_to_actor
import snippets/stream_yielder_basic

pub fn tests() -> TestSuite {
  describe("snippets", [
    group("doc comments and release notes", [
      it("Protocols: h2c_request returns the body over HTTP/2", fn() {
        // Act
        let value =
          protocols_config.h2c_request() |> result.map(fn(r) { r.body })

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("h2c_request should return the body")
      }),
      it("Blocking: fetch_text returns the body", fn() {
        // Act
        let value = blocking_send.fetch_text()

        // Assert
        value
        |> should
        |> be_equal(Ok("Hello, World!"))
        |> or_fail_with("fetch_text should return the body")
      }),
      it("Yielder streaming: count_stream_bytes counts all ten chunks", fn() {
        // Act
        let value = stream_yielder_basic.count_stream_bytes()

        // Assert
        value
        |> should
        |> be_equal(Ok(81))
        |> or_fail_with("Ten chunks should be 81 bytes")
      }),
      it("Process streaming: stream_and_print completes", fn() {
        // Act
        let value = stream_messages_basic.stream_and_print()

        // Assert
        value
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("stream_and_print should complete")
      }),
      it("Message streaming: download_body returns the whole body", fn() {
        // Act
        let value = stream_to_actor.download_body()

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("The actor should collect the whole stream")
      }),
    ]),
  ])
}
