import dream_http_client/recorder.{directory, mode, response_transformer, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/recorded
import fixtures/temp_directory
import fixtures/transformers

pub fn tests() -> TestSuite {
  describe("recorder.response_transformer", [
    it("changes the response before the recorder saves it", fn() {
      // Arrange
      let path = temp_directory.path("response_transformer_scrub")
      let entry =
        recording.Recording(
          request: recorded.text_request(),
          response: recording.BlockingResponse(
            status: 200,
            headers: [#("set-cookie", "secret_cookie=abc123")],
            body: <<"SECRET_BODY">>,
          ),
        )
      let assert Ok(rec) =
        recorder.new()
        |> directory(path)
        |> mode("record")
        |> response_transformer(transformers.scrub_cookies_and_body)
        |> start()

      // Act
      recorder.add_recording(rec, entry)
      let assert Ok(Nil) = recorder.stop(rec)
      let loaded = storage.load_recordings(path)

      // Assert
      loaded
      |> should
      |> be_equal(
        Ok([
          recording.Recording(
            request: recorded.text_request(),
            response: recording.BlockingResponse(
              status: 200,
              headers: [],
              body: <<>>,
            ),
          ),
        ]),
      )
      |> or_fail_with("Saved response should have no cookie and no body")
    }),
  ])
}
