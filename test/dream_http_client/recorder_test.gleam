import dream_http_client/recorder.{
  directory, key, mode, request_transformer, response_transformer, start,
}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recorded
import fixtures/temp_directory
import fixtures/transformers
import gleam/bit_array
import gleam/option.{None, Some}
import gleam/result
import simplifile

pub fn tests() -> TestSuite(Nil) {
  describe("dream_http_client/recorder", [
    group("start", [
      it("starts in record mode with a directory", fn() {
        // Arrange
        let builder =
          recorder.new()
          |> directory(temp_directory.path("recorder_start_record"))
          |> mode("record")

        // Act
        let is_record =
          start(builder)
          |> result.map(fn(rec) {
            let value = recorder.is_record_mode(rec)
            let _stopped = recorder.stop(rec)
            value
          })

        // Assert
        is_record
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("A record recorder should start in record mode")
      }),
      it("starts in playback mode with a directory", fn() {
        // Arrange
        let builder =
          recorder.new()
          |> directory(temp_directory.path("recorder_start_playback"))
          |> mode("playback")

        // Act
        let is_record =
          start(builder)
          |> result.map(fn(rec) {
            let value = recorder.is_record_mode(rec)
            let _stopped = recorder.stop(rec)
            value
          })

        // Assert
        is_record
        |> should
        |> be_equal(Ok(False))
        |> or_fail_with("A playback recorder should not be in record mode")
      }),
      it("starts in passthrough mode by default", fn() {
        // Arrange
        let builder = recorder.new()

        // Act
        let is_record =
          start(builder)
          |> result.map(fn(rec) {
            let value = recorder.is_record_mode(rec)
            let _stopped = recorder.stop(rec)
            value
          })

        // Assert
        is_record
        |> should
        |> be_equal(Ok(False))
        |> or_fail_with("The default recorder should be in passthrough mode")
      }),
      it("returns an error for an unknown mode", fn() {
        // Arrange
        let builder = recorder.new() |> mode("replay")

        // Act
        let started = start(builder) |> result.map(fn(_) { Nil })

        // Assert
        started
        |> should
        |> be_equal(Error(
          "Unknown recorder mode: replay. Expected one of: record, playback, passthrough",
        ))
        |> or_fail_with("An unknown mode should be an error")
      }),
      it("returns an error for record mode with no directory", fn() {
        // Arrange
        let builder = recorder.new() |> mode("record")

        // Act
        let started = start(builder) |> result.map(fn(_) { Nil })

        // Assert
        started
        |> should
        |> be_equal(Error("Recorder directory is required for record/playback"))
        |> or_fail_with("Record mode should need a directory")
      }),
      it("returns an error when playback cannot load the directory", fn() {
        // Arrange
        let path = temp_directory.path("recorder_start_bad_playback")
        let assert Ok(Nil) = simplifile.create_directory_all(path)
        let assert Ok(Nil) = simplifile.write(path <> "/bad.json", "{}")
        let builder = recorder.new() |> directory(path) |> mode("playback")

        // Act
        let started = start(builder) |> result.map(fn(_) { Nil })

        // Assert
        started
        |> should
        |> be_equal(Error(
          "Failed to load recordings in playback mode: Failed to decode "
          <> path
          <> "/bad.json: Expected Field, found Nothing at version",
        ))
        |> or_fail_with("A bad file should stop playback from starting")
      }),
    ]),
    group("add_recording", [
      it("keeps a recording in record mode", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("recorder_add_record"))
          |> mode("record")
          |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        let recordings = recorder.get_recordings(rec)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        recordings
        |> should
        |> be_equal([recorded.text_recording()])
        |> or_fail_with("The recording should be kept")
      }),
      it("saves the recording at once in record mode", fn() {
        // Arrange
        let path = temp_directory.path("recorder_add_saves")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        let _recordings = recorder.get_recordings(rec)
        let loaded = storage.load_recordings(path)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([recorded.text_recording()]))
        |> or_fail_with("The recording should be on disk before stop")
      }),
      it("keeps a duplicate recording only once", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("recorder_add_duplicate"))
          |> mode("record")
          |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        recorder.add_recording(rec, recorded.text_recording())
        let recordings = recorder.get_recordings(rec)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        recordings
        |> should
        |> be_equal([recorded.text_recording()])
        |> or_fail_with("A duplicate recording should not be kept twice")
      }),
      it("keeps two different responses for one key", fn() {
        // Arrange
        let other =
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response("Different"),
          )
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("recorder_add_two"))
          |> mode("record")
          |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        recorder.add_recording(rec, other)
        let recordings = recorder.get_recordings(rec)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        recordings
        |> should
        |> be_equal([other, recorded.text_recording()])
        |> or_fail_with("Both responses should be kept, newest first")
      }),
      it("keeps the recording in memory when the save fails", fn() {
        // Arrange
        let path = temp_directory.path("recorder_add_read_only")
        let assert Ok(Nil) = simplifile.create_directory_all(path)
        let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o555)
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        let recordings = recorder.get_recordings(rec)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        recordings
        |> should
        |> be_equal([recorded.text_recording()])
        |> or_fail_with("A failed save should not lose the recording")
      }),
      it("ignores recordings in passthrough mode", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()

        // Act
        recorder.add_recording(rec, recorded.text_recording())
        let recordings = recorder.get_recordings(rec)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        recordings
        |> should
        |> be_equal([])
        |> or_fail_with("Passthrough mode should keep nothing")
      }),
    ]),
    group("find_recording", [
      it("finds a saved recording in playback mode", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_match")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recorded.text_recording(),
            "GEThttp://localhost:9876/text",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found = recorder.find_recording(rec, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Ok(Some(recorded.text_recording())))
        |> or_fail_with("The saved recording should be found")
      }),
      it("returns None for a request with no recording", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_none")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()
        let request =
          recording.RecordedRequest(..recorded.text_request(), path: "/other")

        // Act
        let found = recorder.find_recording(rec, request)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Ok(None))
        |> or_fail_with("A request with no recording should give None")
      }),
      it("returns None outside playback mode", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("recorder_find_record_mode"))
          |> mode("record")
          |> start()
        recorder.add_recording(rec, recorded.text_recording())

        // Act
        let found = recorder.find_recording(rec, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Ok(None))
        |> or_fail_with("Record mode should never return a recording")
      }),
      it("returns an error when one key has different responses", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_ambiguous")
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        recorder.add_recording(writer, recorded.text_recording())
        recorder.add_recording(
          writer,
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response("Different"),
          ),
        )
        let assert Ok(Nil) = recorder.stop(writer)
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found = recorder.find_recording(rec, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Error(
          "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
        ))
        |> or_fail_with("Different responses for one key should be an error")
      }),
      it("returns an error when one key has different binary responses", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_ambiguous_binary")
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        recorder.add_recording(
          writer,
          recording.Recording(
            ..recorded.text_recording(),
            response: recording.BlockingResponse(200, [], <<255, 0>>),
          ),
        )
        recorder.add_recording(
          writer,
          recording.Recording(
            ..recorded.text_recording(),
            response: recording.BlockingResponse(200, [], <<255, 1>>),
          ),
        )
        let assert Ok(Nil) = recorder.stop(writer)
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found = recorder.find_recording(rec, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Error(
          "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
        ))
        |> or_fail_with(
          "Different binary bodies for one key should be an error",
        )
      }),
      it("returns an error when one key has two streaming responses", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_ambiguous_stream")
        let streaming =
          recording.Recording(
            ..recorded.text_recording(),
            response: recording.StreamingResponse(
              status: 200,
              headers: [],
              chunks: [],
            ),
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, streaming, "first")
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, streaming, "second")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found = recorder.find_recording(rec, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Error(
          "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
        ))
        |> or_fail_with("Streaming responses never count as equal")
      }),
      it("picks one when the responses differ only in auth tokens", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_auth_tokens")
        let token_body = fn(token: String) {
          "{\"AuthenticationResult\":{\"AccessToken\":\""
          <> token
          <> "\",\"IdToken\":\""
          <> token
          <> "\",\"RefreshToken\":\""
          <> token
          <> "\"}}"
        }
        let first =
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response(token_body("aaa")),
          )
        let second =
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response(token_body("bbb")),
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, first, "first")
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, second, "second")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found =
          recorder.find_recording(rec, recorded.text_request())
          |> result.map(option.is_some)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("Responses that differ only in tokens should match")
      }),
      it("keeps an auth body with no IdToken as it is", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_auth_partial")
        let body = fn(token: String) {
          "{\"AuthenticationResult\":{\"AccessToken\":\"" <> token <> "\"}}"
        }
        let first =
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response(body("aaa")),
          )
        let second =
          recording.Recording(
            ..recorded.text_recording(),
            response: recorded.ok_response(body("bbb")),
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, first, "first")
        let assert Ok(Nil) =
          storage.save_recording_immediately(path, second, "second")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let found =
          recorder.find_recording(rec, recorded.text_request())
          |> result.map(option.is_some)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("The AccessToken alone should be normalized")
      }),
      it("uses the key and the request transformer of the builder", fn() {
        // Arrange
        let path = temp_directory.path("recorder_find_custom_key")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.scrubbed_post_request(),
              response: recorded.ok_response("OK"),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new()
          |> directory(path)
          |> mode("playback")
          |> key(fn(request) { bit_array.base64_encode(request.body, True) })
          |> request_transformer(transformers.scrub_auth_and_body)
          |> start()

        // Act
        let found =
          recorder.find_recording(rec, recorded.secret_post_request("abc"))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        found
        |> should
        |> be_equal(
          Ok(
            Some(recording.Recording(
              request: recorded.scrubbed_post_request(),
              response: recorded.ok_response("OK"),
            )),
          ),
        )
        |> or_fail_with("The custom key should match the scrubbed request")
      }),
    ]),
    group("transform_response", [
      it("applies the response transformer", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> response_transformer(transformers.scrub_cookies_and_body)
          |> start()
        let response =
          recording.BlockingResponse(
            status: 200,
            headers: [#("set-cookie", "a=b"), #("Content-Type", "text/plain")],
            body: <<"secret data">>,
          )

        // Act
        let transformed =
          recorder.transform_response(rec, recorded.text_request(), response)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        transformed
        |> should
        |> be_equal(
          recording.BlockingResponse(
            status: 200,
            headers: [#("Content-Type", "text/plain")],
            body: <<>>,
          ),
        )
        |> or_fail_with("The transformer should scrub the response")
      }),
      it("returns the response unchanged with no transformer", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()
        let response = recorded.ok_response("untouched data")

        // Act
        let transformed =
          recorder.transform_response(rec, recorded.text_request(), response)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        transformed
        |> should
        |> be_equal(recorded.ok_response("untouched data"))
        |> or_fail_with("The response should not change")
      }),
    ]),
    group("a stopped recorder", [
      it("is_record_mode returns False", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("recorder_stopped_mode"))
          |> mode("record")
          |> start()
        let assert Ok(Nil) = recorder.stop(rec)

        // Act
        let value = recorder.is_record_mode(rec)

        // Assert
        value
        |> should
        |> be_equal(False)
        |> or_fail_with("A stopped recorder should not report record mode")
      }),
      it("transform_response returns the response unchanged", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> response_transformer(transformers.scrub_cookies_and_body)
          |> start()
        let assert Ok(Nil) = recorder.stop(rec)

        // Act
        let value =
          recorder.transform_response(
            rec,
            recorded.text_request(),
            recorded.ok_response("kept"),
          )

        // Assert
        value
        |> should
        |> be_equal(recorded.ok_response("kept"))
        |> or_fail_with("A stopped recorder should not transform")
      }),
      it("find_recording returns None", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()
        let assert Ok(Nil) = recorder.stop(rec)

        // Act
        let value = recorder.find_recording(rec, recorded.text_request())

        // Assert
        value
        |> should
        |> be_equal(Ok(None))
        |> or_fail_with("A stopped recorder should find nothing")
      }),
      it("get_recordings returns an empty list", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()
        let assert Ok(Nil) = recorder.stop(rec)

        // Act
        let value = recorder.get_recordings(rec)

        // Assert
        value
        |> should
        |> be_equal([])
        |> or_fail_with("A stopped recorder should return no recordings")
      }),
      it("stop returns an error", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()
        let assert Ok(Nil) = recorder.stop(rec)

        // Act
        let value = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Error("Recorder did not respond within 5 seconds: Nil"))
        |> or_fail_with("Stopping twice should time out")
      }),
    ]),
  ])
}
