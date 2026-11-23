//// Tests for the code blocks in the dream_http_client README, and for the
//// other snippets in test/snippets/.
////
//// The requests go to dream_mock_server, which the test main starts on
//// localhost:9876.

import dream_http_client/client
import dream_http_client/recorder
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recorded
import fixtures/temp_directory
import gleam/option.{Some}
import gleam/result
import snippets/blocking_request
import snippets/blocking_send
import snippets/matching_config
import snippets/per_request_settings
import snippets/post_json
import snippets/protocols_config
import snippets/recording_ambiguous_match
import snippets/recording_basic
import snippets/recording_playback
import snippets/recording_response_transformer
import snippets/recording_start_stream
import snippets/recording_stream_yielder
import snippets/recording_transformer
import snippets/request_builder
import snippets/stream_cancel
import snippets/stream_messages_basic
import snippets/stream_to_actor
import snippets/stream_yielder_basic
import snippets/timeout_config
import snippets/transport_config_example

pub fn tests() -> TestSuite(Nil) {
  describe("snippets", [
    group("README", [
      it("Quick Start: simple_get returns the text endpoint", fn() {
        // Act
        let value =
          blocking_request.simple_get()
          |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("simple_get should return the text endpoint")
      }),
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
      it(
        "Per-request settings: fetch_with_connect_timeout returns the text endpoint",
        fn() {
          // Act
          let value =
            per_request_settings.fetch_with_connect_timeout()
            |> result.map(fn(r) { #(r.status, r.body) })

          // Assert
          value
          |> should
          |> be_equal(Ok(#(200, <<"Hello, World!">>)))
          |> or_fail_with("The text endpoint should answer")
        },
      ),
      it("Per-request settings: fetch_without_redirect returns the 302", fn() {
        // Act
        let value =
          per_request_settings.fetch_without_redirect()
          |> result.map(fn(r) { r.status })

        // Assert
        value
        |> should
        |> be_equal(Ok(302))
        |> or_fail_with("The redirect should not be followed")
      }),
      it("Transport settings: configure_high_concurrency returns Nil", fn() {
        // Act
        let value = transport_config_example.configure_high_concurrency()
        client.configure_transport(client.transport_config())

        // Assert
        value
        |> should
        |> be_equal(Nil)
        |> or_fail_with("configure_high_concurrency should return Nil")
      }),
      it("Recording: record_text returns the real response", fn() {
        // Arrange
        let directory = temp_directory.path("snippet_recording_basic_record")

        // Act
        let value =
          recording_basic.record_text(directory)
          |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("record_text should return the real response")
      }),
      it("Recording: play_back_text returns the recorded response", fn() {
        // Arrange
        let directory = temp_directory.path("snippet_recording_basic_playback")
        let assert Ok(_recorded) = recording_basic.record_text(directory)

        // Act
        let value =
          recording_basic.play_back_text(directory)
          |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("play_back_text should return the recording")
      }),
      it("Testing: fetch_recorded_text returns the fixture response", fn() {
        // Arrange
        let assert Ok(playback) = recording_playback.start_api_playback()

        // Act
        let value =
          recording_playback.fetch_recorded_text(playback)
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(playback)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Recorded text from the fixture">>)))
        |> or_fail_with("The fixture response should come back")
      }),
      it("Request matching: method_and_url_key ignores headers and body", fn() {
        // Arrange
        let request_key = matching_config.method_and_url_key()
        let first =
          recording.RecordedRequest(
            ..recorded.text_request(),
            headers: [#("Authorization", "Bearer one")],
            body: <<"a">>,
          )
        let second =
          recording.RecordedRequest(
            ..recorded.text_request(),
            headers: [#("Authorization", "Bearer two")],
            body: <<"b">>,
          )

        // Act
        let value = #(request_key(first), request_key(second))

        // Assert
        value
        |> should
        |> be_equal(#(
          "GEThttp://localhost:9876/text",
          "GEThttp://localhost:9876/text",
        ))
        |> or_fail_with("Both requests should get the same key")
      }),
      it(
        "Request matching: start_playback finds a recording with other headers",
        fn() {
          // Arrange
          let directory = temp_directory.path("snippet_matching_config")
          let saved =
            recording.Recording(
              request: recording.RecordedRequest(
                ..recorded.text_request(),
                headers: [#("Authorization", "Bearer one")],
                body: <<"a">>,
              ),
              response: recorded.ok_response("ok"),
            )
          let assert Ok(Nil) =
            storage.save_recording_immediately(directory, saved, "k")
          let assert Ok(playback) = matching_config.start_playback(directory)

          // Act
          let value =
            recorder.find_recording(
              playback,
              recording.RecordedRequest(
                ..recorded.text_request(),
                headers: [#("Authorization", "Bearer two")],
                body: <<"b">>,
              ),
            )
          let assert Ok(Nil) = recorder.stop(playback)

          // Assert
          value
          |> should
          |> be_equal(
            Ok(
              Some(recording.Recording(
                request: recording.RecordedRequest(
                  ..recorded.text_request(),
                  headers: [#("Authorization", "Bearer one")],
                  body: <<"a">>,
                ),
                response: recorded.ok_response("ok"),
              )),
            ),
          )
          |> or_fail_with("The recording should match by method and URL")
        },
      ),
      it("Transformers: scrub_auth_and_body removes the secrets", fn() {
        // Arrange
        let request =
          recording.RecordedRequest(
            ..recorded.text_request(),
            headers: [#("Authorization", "Bearer secret"), #("X-Ok", "1")],
            body: <<"body">>,
          )

        // Act
        let value = recording_transformer.scrub_auth_and_body(request)

        // Assert
        value
        |> should
        |> be_equal(
          recording.RecordedRequest(..recorded.text_request(), headers: [
            #("X-Ok", "1"),
          ]),
        )
        |> or_fail_with("The secrets should be removed")
      }),
      it(
        "Transformers: start_scrubbing_recorder saves the scrubbed request",
        fn() {
          // Arrange
          let directory = temp_directory.path("snippet_recording_transformer")
          let assert Ok(rec) =
            recording_transformer.start_scrubbing_recorder(directory)
          let request =
            recording.RecordedRequest(
              ..recorded.text_request(),
              headers: [#("Authorization", "Bearer secret"), #("X-Ok", "1")],
              body: <<"{\"secret\":\"value\"}">>,
            )

          // Act
          recorder.add_recording(
            rec,
            recording.Recording(
              request: request,
              response: recorded.ok_response("OK"),
            ),
          )
          let assert Ok(Nil) = recorder.stop(rec)
          let value = storage.load_recordings(directory)

          // Assert
          value
          |> should
          |> be_equal(
            Ok([
              recording.Recording(
                request: recording.RecordedRequest(
                  ..recorded.text_request(),
                  headers: [#("X-Ok", "1")],
                ),
                response: recorded.ok_response("OK"),
              ),
            ]),
          )
          |> or_fail_with("The saved request should be scrubbed")
        },
      ),
      it("Transformers: scrub_response removes cookies and body", fn() {
        // Arrange
        let response =
          recording.BlockingResponse(
            status: 200,
            headers: [#("set-cookie", "secret_cookie=abc123"), #("X-Ok", "1")],
            body: <<"SECRET_BODY">>,
          )

        // Act
        let value =
          recording_response_transformer.scrub_response(
            recorded.text_request(),
            response,
          )

        // Assert
        value
        |> should
        |> be_equal(
          recording.BlockingResponse(
            status: 200,
            headers: [#("X-Ok", "1")],
            body: <<>>,
          ),
        )
        |> or_fail_with("Cookies and body should be removed")
      }),
      it(
        "Transformers: the response scrubbing recorder saves the scrubbed response",
        fn() {
          // Arrange
          let directory = temp_directory.path("snippet_response_transformer")
          let assert Ok(rec) =
            recording_response_transformer.start_scrubbing_recorder(directory)
          let response =
            recording.BlockingResponse(
              status: 200,
              headers: [#("set-cookie", "secret_cookie=abc123")],
              body: <<"SECRET_BODY">>,
            )

          // Act
          recorder.add_recording(
            rec,
            recording.Recording(
              request: recorded.text_request(),
              response: response,
            ),
          )
          let assert Ok(Nil) = recorder.stop(rec)
          let value = storage.load_recordings(directory)

          // Assert
          value
          |> should
          |> be_equal(
            Ok([
              recording.Recording(
                request: recorded.text_request(),
                response: recorded.ok_response(""),
              ),
            ]),
          )
          |> or_fail_with("The saved response should be scrubbed")
        },
      ),
      it("Ambiguous matches: start_playback reports an ambiguous match", fn() {
        // Arrange
        let directory = temp_directory.path("snippet_ambiguous_match")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            directory,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("one"),
            ),
            "GEThttp://localhost:9876/text",
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            directory,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("two"),
            ),
            "GEThttp://localhost:9876/text",
          )
        let assert Ok(playback) =
          recording_ambiguous_match.start_playback(directory)

        // Act
        let value = recorder.find_recording(playback, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(playback)

        // Assert
        value
        |> should
        |> be_equal(Error(
          "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
        ))
        |> or_fail_with("Two different responses should be ambiguous")
      }),
      it("Builder pattern: send_post echoes the body", fn() {
        // Act
        let value =
          request_builder.send_post()
          |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(201, <<
              "{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"{\\\"hello\\\":\\\"world\\\"}\"}",
            >>),
          ),
        )
        |> or_fail_with("send_post should get the echo")
      }),
      it("Error handling: fetch_text_with_timeout returns the body", fn() {
        // Act
        let value = timeout_config.fetch_text_with_timeout()

        // Assert
        value
        |> should
        |> be_equal(Ok("Hello, World!"))
        |> or_fail_with("fetch_text_with_timeout should return the body")
      }),
    ]),
    group("other snippets", [
      it("post_json: post_user gets the echo", fn() {
        // Act
        let value =
          post_json.post_user() |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(201, <<
              "{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"{\\\"name\\\":\\\"Alice\\\",\\\"email\\\":\\\"alice@example.com\\\"}\"}",
            >>),
          ),
        )
        |> or_fail_with("post_user should get the echo")
      }),
      it("stream_cancel: cancel_stream stops the stream", fn() {
        // Act
        let value = stream_cancel.cancel_stream()

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("The stream should stop")
      }),
      it("recording_stream_yielder: playback matches the recording", fn() {
        // Act
        let value =
          recording_stream_yielder.record_and_playback_stream_yielder()

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("Playback should give the recorded bytes")
      }),
      it("recording_start_stream: playback matches the recording", fn() {
        // Act
        let value = recording_start_stream.record_and_playback_start_stream()

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("Playback should give the recorded chunks")
      }),
    ]),
  ])
}
