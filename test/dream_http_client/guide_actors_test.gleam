//// Tests for the snippets of the streaming to actors guide
//// (docs/guides/streaming-to-actors.md). Each test starts the tracker actor
//// on a stream of the local mock server and asserts the exact progress
//// that the guide shows.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import snippets/guide_actors_tracker.{
  type Message, type Progress, Progress, cancel, progress, start_tracker,
}

pub fn tests() -> TestSuite {
  describe("streaming to actors guide", [
    it("step 3: the tracker answers before the stream ends", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/slow"))

      // Act
      let first = progress(tracker)
      cancel(tracker)

      // Assert
      first
      |> should
      |> be_equal(Progress(bytes: 0, chunks: 0, finished: False, failure: None))
      |> or_fail_with("The tracker should answer at once")
    }),
    it("step 2: the tracker counts the ten chunks of /stream/fast", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/fast"))

      // Act
      let final = await_finished(tracker, 50)

      // Assert
      final
      |> should
      |> be_equal(Progress(bytes: 81, chunks: 10, finished: True, failure: None))
      |> or_fail_with("All ten chunks should arrive")
    }),
    it("failures: the tracker keeps an error status", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/error"))

      // Act
      let final = await_finished(tracker, 50)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 0,
        chunks: 0,
        finished: True,
        failure: Some(
          "HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
        ),
      ))
      |> or_fail_with("A 500 should end the stream with no chunks")
    }),
    it("failures: the tracker keeps the chunks before a drop", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/drop"))

      // Act
      let final = await_finished(tracker, 50)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 26,
        chunks: 2,
        finished: True,
        failure: Some("Remote closed connection"),
      ))
      |> or_fail_with("A drop should keep the first two chunks")
    }),
    it("failures: a refused connection arrives as a message", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.closed_port("/"))

      // Act
      let final = await_finished(tracker, 50)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 0,
        chunks: 0,
        finished: True,
        failure: Some("Connection failed: Connection refused"),
      ))
      |> or_fail_with("A refused connection should be a StreamError")
    }),
    it("step 4: a cancelled stream sends no more chunks", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/slow"))

      // Act
      cancel(tracker)
      // The first chunk of /stream/slow comes after 2 seconds
      process.sleep(2500)
      let final = progress(tracker)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 0,
        chunks: 0,
        finished: True,
        failure: Some("Cancelled"),
      ))
      |> or_fail_with("No chunk should arrive after the cancel")
    }),
  ])
}

fn await_finished(tracker: Subject(Message), attempts: Int) -> Progress {
  let current = progress(tracker)
  case current.finished || attempts <= 1 {
    True -> current
    False -> {
      process.sleep(100)
      await_finished(tracker, attempts - 1)
    }
  }
}
