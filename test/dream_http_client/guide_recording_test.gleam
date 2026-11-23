//// Tests for the snippets of the recording guide
//// (docs/guides/recording-and-playback.md). The tests record from a mock
//// server on its own port, stop the server, and play the recordings back,
//// so playback can reach no server. They assert the exact values that the
//// guide shows.

import dream_http_client/client.{NoRecording, RequestError}
import dream_http_client/matching
import dream_http_client/recorder
import dream_http_client/recording.{BlockingResponse, RecordedRequest, Recording}
import dream_http_client/storage
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/temp_directory
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import snippets/guide_recording_by_hand.{save_rate_limit_recording}
import snippets/guide_recording_client.{fetch_text, start_recorder}
import snippets/guide_recording_inspect.{recorded_statuses}
import snippets/guide_recording_round_trip.{play_back_text, record_text}
import snippets/guide_recording_stream.{fetch_chunks}

const fast_chunks = [
  <<"Chunk 1\n">>,
  <<"Chunk 2\n">>,
  <<"Chunk 3\n">>,
  <<"Chunk 4\n">>,
  <<"Chunk 5\n">>,
  <<"Chunk 6\n">>,
  <<"Chunk 7\n">>,
  <<"Chunk 8\n">>,
  <<"Chunk 9\n">>,
  <<"Chunk 10\n">>,
]

pub fn tests() -> TestSuite {
  describe("recording guide", [
    group("steps 1 to 3: record, then play back with no server", [
      it("record mode returns the live answer", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_step1")
        let assert Ok(mock) = server.start(19_991)

        // Act
        let text = record_text(api(19_991), recordings)
        server.stop(mock)

        // Assert
        text
        |> should
        |> be_equal(Ok("Hello, World!"))
        |> or_fail_with("Record mode should send the request")
      }),
      it("record mode writes one file for each request", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_files")
        record_text_and_stream(recordings, 19_992)

        // Act
        let names =
          simplifile.read_directory(recordings)
          |> result.map(fn(files) {
            files |> list.map(name_without_hashes) |> list.sort(string.compare)
          })

        // Assert
        names
        |> should
        |> be_equal(Ok(["GET_localhost__stream_fast", "GET_localhost__text"]))
        |> or_fail_with("Expected one file for each request")
      }),
      it("playback returns the recorded text with no server", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_playback")
        record_text_and_stream(recordings, 19_993)

        // Act
        let text = play_back_text(api(19_993), recordings)

        // Assert
        text
        |> should
        |> be_equal(Ok("Hello, World!"))
        |> or_fail_with("Playback should answer without the server")
      }),
      it("without the recorder the stopped server is unreachable", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_unreachable")
        record_text_and_stream(recordings, 19_994)

        // Act
        let text = fetch_text(api(19_994))

        // Assert
        text
        |> should
        |> be_equal(Error("Connection failed: Connection refused"))
        |> or_fail_with("The server is stopped")
      }),
      it("playback returns the ten recorded chunks", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_stream")
        record_text_and_stream(recordings, 19_995)
        let assert Ok(playback) = start_recorder("playback", recordings)

        // Act
        let chunks = fetch_chunks(api(19_995) |> client.recorder(playback))

        // Assert
        chunks
        |> should
        |> be_equal(Ok(fast_chunks))
        |> or_fail_with("Playback should keep the chunk boundaries")
      }),
    ]),
    group("step 4: no recording", [
      it("a request with no recording is not sent", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_miss")
        record_text_and_stream(recordings, 19_996)
        let assert Ok(playback) = start_recorder("playback", recordings)

        // Act
        let result =
          api(19_996)
          |> client.path("/json")
          |> client.recorder(playback)
          |> client.send()
          |> result.map(fn(response) { response.status })

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            RequestError(NoRecording(
              method: "GET",
              url: "http://localhost:19996/json",
            )),
          ),
        )
        |> or_fail_with("A playback miss should name the request")
      }),
      it("passthrough mode sends the request and records nothing", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_passthrough")
        let assert Ok(passthrough) = start_recorder("passthrough", recordings)

        // Act
        let text = fetch_text(api(9876) |> client.recorder(passthrough))
        let saved = recorder.get_recordings(passthrough)

        // Assert
        #(text, saved)
        |> should
        |> be_equal(#(Ok("Hello, World!"), []))
        |> or_fail_with("Passthrough should only send the request")
      }),
    ]),
    group("step 5: a recording by hand", [
      it("save_rate_limit_recording writes the file", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_by_hand")

        // Act
        let assert Ok(Nil) = save_rate_limit_recording(recordings)
        let content =
          simplifile.read(
            recordings <> "/GET_localhost__text_7646ad_f0cb30.json",
          )

        // Assert
        content
        |> should
        |> be_equal(Ok(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"http\",\"host\":\"localhost\",\"port\":9876,\"path\":\"/text\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":429,\"headers\":[[\"retry-after\",\"30\"]],\"body\":\"Slow down\"}}]}",
        ))
        |> or_fail_with("Expected the JSON of the recording")
      }),
      it("playback returns the hand-written 429", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_429")
        let assert Ok(Nil) = save_rate_limit_recording(recordings)
        let assert Ok(playback) = start_recorder("playback", recordings)

        // Act
        let text = fetch_text(api(9876) |> client.recorder(playback))

        // Assert
        text
        |> should
        |> be_equal(Error("HTTP 429"))
        |> or_fail_with("The recording should answer 429")
      }),
      it("recorded_statuses reads the status of the 429 file", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_inspect")
        let assert Ok(Nil) = save_rate_limit_recording(recordings)

        // Act
        let statuses =
          recorded_statuses(
            recordings <> "/GET_localhost__text_7646ad_f0cb30.json",
          )

        // Assert
        statuses
        |> should
        |> be_equal(Ok([429]))
        |> or_fail_with("The file holds one recording with status 429")
      }),
      it("encode_recording_file writes the JSON that it reads", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_encode")
        let assert Ok(Nil) = save_rate_limit_recording(recordings)
        let assert Ok(text) =
          simplifile.read(
            recordings <> "/GET_localhost__text_7646ad_f0cb30.json",
          )

        // Act
        let encoded =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            json.to_string(recording.encode_recording_file(file))
          })

        // Assert
        encoded
        |> should
        |> be_equal(Ok(text))
        |> or_fail_with("Decoding and encoding should give the same JSON")
      }),
      it("save_recordings writes one file for each recording", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_save_many")
        let second =
          Recording(
            ..hand_recording(),
            request: RecordedRequest(..hand_recording().request, path: "/teams"),
          )
        let key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: False,
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(recordings, [hand_recording(), second], key)
        let count =
          simplifile.read_directory(recordings) |> result.map(list.length)

        // Assert
        count
        |> should
        |> be_equal(Ok(2))
        |> or_fail_with("Two recordings should give two files")
      }),
      it("is_record_mode tells a recording recorder apart", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_is_record")
        let assert Ok(recording_recorder) = start_recorder("record", recordings)
        let assert Ok(passthrough) = start_recorder("passthrough", recordings)

        // Act
        let modes = #(
          recorder.is_record_mode(recording_recorder),
          recorder.is_record_mode(passthrough),
        )

        // Assert
        modes
        |> should
        |> be_equal(#(True, False))
        |> or_fail_with("Only the record recorder records")
      }),
      it("add_recording keeps the recording in record mode", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_add_record")
        let assert Ok(recorder) = start_recorder("record", recordings)

        // Act
        recorder.add_recording(recorder, hand_recording())
        let count = list.length(recorder.get_recordings(recorder))

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("Record mode keeps the added recording")
      }),
      it("add_recording does nothing in playback mode", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_recording_add_playback")
        let assert Ok(Nil) = simplifile.create_directory_all(recordings)
        let assert Ok(playback) = start_recorder("playback", recordings)

        // Act
        recorder.add_recording(playback, hand_recording())
        let count = list.length(recorder.get_recordings(playback))

        // Assert
        count
        |> should
        |> be_equal(0)
        |> or_fail_with("Playback mode ignores add_recording")
      }),
    ]),
  ])
}

fn api(port: Int) -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(port)
}

/// Records /text and /stream/fast from a mock server on `port`, then stops
/// the server.
fn record_text_and_stream(recordings: String, port: Int) -> Nil {
  let assert Ok(mock) = server.start(port)
  let assert Ok(recorder) = start_recorder("record", recordings)
  let _text = fetch_text(api(port) |> client.recorder(recorder))
  let _chunks = fetch_chunks(api(port) |> client.recorder(recorder))
  let assert Ok(Nil) = recorder.stop(recorder)
  server.stop(mock)
}

/// A file name without its two hashes and its extension.
fn name_without_hashes(file: String) -> String {
  let parts = string.split(file, "_")
  parts
  |> list.take(list.length(parts) - 2)
  |> string.join("_")
}

fn hand_recording() -> recording.Recording {
  Recording(
    request: RecordedRequest(
      method: http.Get,
      scheme: http.Https,
      host: "api.example.com",
      port: None,
      path: "/users",
      query: Some("page=1"),
      headers: [],
      body: <<>>,
    ),
    response: BlockingResponse(status: 200, headers: [], body: <<"[]">>),
  )
}
