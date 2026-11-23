//// Guide: Streaming a response, testing
////
//// Tests print_events against its own mock server, and against a recording
//// that splits a line across two chunks.

import dream_http_client/client.{
  host, path, port, recorder as with_recorder, scheme,
}
import dream_http_client/matching
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording.{Chunk, RecordedRequest, StreamingResponse}
import dream_http_client/storage
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None}
import simplifile
import snippets/guide_streaming_json_lines.{print_events}

const mock_port = 19_970

pub fn tests() -> TestSuite {
  describe("print_events", [
    it("prints the five events of a JSON lines stream", fn() {
      // Arrange
      let assert Ok(mock) = server.start(mock_port)
      let request =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(mock_port)
        |> path("/stream/json")

      // Act
      let printed = print_events(request)
      server.stop(mock)

      // Assert
      printed
      |> should
      |> be_equal(Ok(5))
      |> or_fail_with("Expected five events")
    }),
    it("joins a line that arrives in two chunks", fn() {
      // Arrange
      // Start from an empty directory of recordings
      let recordings = "build/guide_streaming_recordings"
      let assert Ok(Nil) = simplifile.create_directory_all(recordings)
      let assert Ok(Nil) = simplifile.delete(recordings)
      let split_line =
        recording.Recording(
          request: RecordedRequest(
            method: http.Get,
            scheme: http.Https,
            host: "api.example.com",
            port: None,
            path: "/events",
            query: None,
            headers: [],
            body: <<>>,
          ),
          response: StreamingResponse(status: 200, headers: [], chunks: [
            Chunk(data: <<"{\"message\":\"first\"}\n{\"mess">>, delay_ms: 0),
            Chunk(data: <<"age\":\"second\"}\n">>, delay_ms: 0),
          ]),
        )
      let key =
        matching.request_key(
          method: True,
          url: True,
          headers: False,
          body: False,
        )
      let assert Ok(Nil) =
        storage.save_recording_immediately(
          recordings,
          split_line,
          key(split_line.request),
        )
      let assert Ok(playback) =
        recorder.new() |> directory(recordings) |> mode("playback") |> start()
      let request =
        client.new()
        |> host("api.example.com")
        |> path("/events")
        |> with_recorder(playback)

      // Act
      let printed = print_events(request)

      // Assert
      printed
      |> should
      |> be_equal(Ok(2))
      |> or_fail_with("Expected both events, the second one joined")
    }),
  ])
}
