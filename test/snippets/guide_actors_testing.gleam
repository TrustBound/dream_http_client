//// Guide: Streaming into an OTP actor, testing
////
//// Tests the tracker actor against its own mock server: a stream that
//// ends, and a stream that drops.

import dream_http_client/client.{host, path, port, scheme}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/option.{None, Some}
import snippets/guide_actors_tracker.{
  type Message, type Progress, Progress, progress, start_tracker,
}

pub fn tests() -> TestSuite {
  describe("tracker", [
    it("counts every chunk of a stream that ends", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_978)
      let assert Ok(tracker) = start_tracker(stream_request(19_978, "/fast"))

      // Act
      let final = await_finished(tracker, 50)
      server.stop(mock)

      // Assert
      final
      |> should
      |> be_equal(Progress(bytes: 81, chunks: 10, finished: True, failure: None))
      |> or_fail_with("Expected all ten chunks")
    }),
    it("keeps the chunks that came before a drop", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_979)
      let assert Ok(tracker) = start_tracker(stream_request(19_979, "/drop"))

      // Act
      let final = await_finished(tracker, 50)
      server.stop(mock)

      // Assert
      final
      |> should
      |> be_equal(Progress(
        bytes: 26,
        chunks: 2,
        finished: True,
        failure: Some("Remote closed connection"),
      ))
      |> or_fail_with("Expected two chunks and the failure")
    }),
  ])
}

fn stream_request(mock_port: Int, stream: String) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
  |> path("/stream" <> stream)
}

/// Asks for the progress every 100 ms until the stream is finished, at most
/// `attempts` times.
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
