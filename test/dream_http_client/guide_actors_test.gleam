//// Tests for the snippets of the streaming to actors guide
//// (docs/guides/streaming-to-actors.md). Each test starts the tracker actor
//// on a stream of the local mock server and asserts the exact progress
//// that the guide shows. The output that the guide shows in a `text` block
//// is a file in `test/outputs/`, and the tests compare it with the real
//// output.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mock_server
import fixtures/output_file
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{Some}
import gleam/string
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
      output_file.lines([shown(first)])
      |> should
      |> be_equal(output_file.read("guide_actors_progress_start"))
      |> or_fail_with("The tracker should answer at once")
    }),
    it("step 2: the tracker counts the ten chunks of /stream/fast", fn() {
      // Arrange
      let assert Ok(tracker) = start_tracker(mock_server.get("/stream/fast"))

      // Act
      let final = await_finished(tracker, 50)

      // Assert
      output_file.lines([shown(final)])
      |> should
      |> be_equal(output_file.read("guide_actors_progress_end"))
      |> or_fail_with("All ten chunks should arrive")
    }),
    it("failures: an error status, and the chunks before a drop", fn() {
      // Arrange
      let assert Ok(error_tracker) =
        start_tracker(mock_server.get("/stream/error"))
      let assert Ok(drop_tracker) =
        start_tracker(mock_server.get("/stream/drop"))

      // Act
      let lines = [
        "/stream/error  -> " <> shown(await_finished(error_tracker, 50)),
        "/stream/drop   -> " <> shown(await_finished(drop_tracker, 50)),
      ]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_actors_failures"))
      |> or_fail_with("A 500 has no chunks, and a drop keeps two")
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
      output_file.lines([shown(final)])
      |> should
      |> be_equal(output_file.read("guide_actors_cancel"))
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

/// The progress with the names of its fields, as the guide shows it.
fn shown(progress: Progress) -> String {
  "Progress(bytes: "
  <> int.to_string(progress.bytes)
  <> ", chunks: "
  <> int.to_string(progress.chunks)
  <> ", finished: "
  <> bool.to_string(progress.finished)
  <> ", failure: "
  <> string.inspect(progress.failure)
  <> ")"
}
