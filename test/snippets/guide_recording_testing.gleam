//// Guide: Testing with recorded responses, testing
////
//// Tests fetch_text with the recordings in test/fixtures/api, with no
//// server.

import dream_http_client/client.{host, port, recorder as with_recorder, scheme}
import dream_http_client/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import snippets/guide_recording_client.{fetch_text, start_recorder}

pub fn tests() -> TestSuite {
  describe("fetch_text", [
    it("reads the recorded text", fn() {
      // Arrange
      let assert Ok(playback) =
        start_recorder(recorder.Playback, "test/fixtures/api")
      let api =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(9876)
        |> with_recorder(playback)

      // Act
      let text = fetch_text(api)

      // Assert
      text
      |> should
      |> be_equal(Ok("Recorded text from the fixture"))
      |> or_fail_with("Expected the text of the recording")
    }),
  ])
}
