import dream_http_client/matching
import dream_http_client/recorder.{
  directory, key, mode, request_transformer, start,
}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/recorded
import fixtures/temp_directory
import fixtures/transformers
import gleam/option

pub fn tests() -> TestSuite {
  describe("recorder.request_transformer", [
    it("changes the request before the recorder saves it", fn() {
      // Arrange
      let path = temp_directory.path("request_transformer_persist")
      let assert Ok(rec) =
        recorder.new()
        |> directory(path)
        |> mode("record")
        |> key(matching.request_key(
          method: True,
          url: True,
          headers: True,
          body: True,
        ))
        |> request_transformer(transformers.scrub_auth_and_body)
        |> start()

      // Act
      recorder.add_recording(
        rec,
        recording.Recording(
          request: recorded.secret_post_request("secret"),
          response: recorded.ok_response("OK"),
        ),
      )
      let assert Ok(Nil) = recorder.stop(rec)
      let loaded = storage.load_recordings(path)

      // Assert
      loaded
      |> should
      |> be_equal(
        Ok([
          recording.Recording(
            request: recorded.scrubbed_post_request(),
            response: recorded.ok_response("OK"),
          ),
        ]),
      )
      |> or_fail_with("Saved request should have no Authorization and no body")
    }),
    it("finds a recording for a request with a different secret", fn() {
      // Arrange
      let path = temp_directory.path("request_transformer_playback")
      let assert Ok(rec) =
        recorder.new()
        |> directory(path)
        |> mode("record")
        |> key(matching.request_key(
          method: True,
          url: True,
          headers: True,
          body: True,
        ))
        |> request_transformer(transformers.scrub_auth_and_body)
        |> start()
      recorder.add_recording(
        rec,
        recording.Recording(
          request: recorded.secret_post_request("secret"),
          response: recorded.ok_response("OK"),
        ),
      )
      let assert Ok(Nil) = recorder.stop(rec)
      let assert Ok(playback) =
        recorder.new()
        |> directory(path)
        |> mode("playback")
        |> key(matching.request_key(
          method: True,
          url: True,
          headers: True,
          body: True,
        ))
        |> request_transformer(transformers.scrub_auth_and_body)
        |> start()

      // Act
      let found =
        recorder.find_recording(
          playback,
          recorded.secret_post_request("different"),
        )
      let assert Ok(Nil) = recorder.stop(playback)

      // Assert
      found
      |> should
      |> be_equal(
        Ok(
          option.Some(recording.Recording(
            request: recorded.scrubbed_post_request(),
            response: recorded.ok_response("OK"),
          )),
        ),
      )
      |> or_fail_with("The transformed request should match the recording")
    }),
  ])
}
