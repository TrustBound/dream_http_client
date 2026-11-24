//// Guide: Matching requests and hiding secrets in recordings, testing
////
//// Checks that a recording made through the scrubbing recorder holds no
//// token.

import dream_http_client/client.{
  add_header, host, path, port, recorder as with_recorder, scheme, send,
}
import dream_http_client/recorder
import dream_http_client/recording.{type Recording}
import dream_http_client/storage
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/list
import gleam/result
import simplifile
import snippets/guide_matching_scrub.{start_scrubbing_recorder}

pub fn tests() -> TestSuite {
  describe("scrubbing recorder", [
    it("saves the request without its Authorization header", fn() {
      // Arrange
      let recordings = "build/guide_matching_recordings"
      let _deleted = simplifile.delete(recordings)
      let assert Ok(mock) = server.start(19_997)
      let assert Ok(scrubbing) =
        start_scrubbing_recorder(recorder.Record, recordings)

      // Act
      let _response =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(19_997)
        |> path("/text")
        |> add_header("Authorization", "Bearer test-token-123")
        |> with_recorder(scrubbing)
        |> send()
      let assert Ok(Nil) = recorder.stop(scrubbing)
      server.stop(mock)
      let saved_headers =
        storage.load_recordings(recordings)
        |> result.map(list.map(_, request_headers))

      // Assert
      saved_headers
      |> should
      |> be_equal(Ok([[]]))
      |> or_fail_with("Expected one recording with no headers")
    }),
  ])
}

fn request_headers(saved: Recording) -> List(#(String, String)) {
  saved.request.headers
}
