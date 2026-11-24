import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recorded
import fixtures/temp_directory
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

// The file name of a recording of `GET http://localhost:9876/text`.
const text_file = "GET_localhost__text_7646ad0d38469745.json"

// The file name of a recording of `GET http://localhost:9876/other`.
const other_file = "GET_localhost__other_b2ba8f51c9d73c28.json"

// The file name of a recording of `GET http://localhost:9876/stream`.
const stream_file = "GET_localhost__stream_7d8ce761e7ea8b5e.json"

// The 5.x file name of `recorded.text_recording()`, with a content hash.
const old_text_file = "GET_localhost__text_7646ad_f1bb9a.json"

pub fn tests() -> TestSuite {
  describe("dream_http_client/recorder record runs", [
    group("a record run replaces what it records again", [
      it("keeps one file for a request recorded with a new response", fn() {
        // Arrange
        let path = temp_directory.path("replace_one_file")
        let assert Ok(Nil) = record_run(path, [recorded.text_recording()])

        // Act
        let assert Ok(Nil) = record_run(path, [changed_text_recording()])
        let files = sorted_files(path)

        // Assert
        files
        |> should
        |> be_equal(Ok([text_file]))
        |> or_fail_with("A record run should replace the old recording")
      }),
      it("writes the new response to that file", fn() {
        // Arrange
        let path = temp_directory.path("replace_new_content")
        let assert Ok(Nil) = record_run(path, [recorded.text_recording()])

        // Act
        let assert Ok(Nil) = record_run(path, [changed_text_recording()])
        let loaded = storage.load_recordings(path)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([changed_text_recording()]))
        |> or_fail_with("The file should hold the new response")
      }),
      it("plays back the new response after the record run", fn() {
        // Arrange
        let path = temp_directory.path("replace_playback")
        let assert Ok(Nil) = record_run(path, [recorded.text_recording()])
        let assert Ok(Nil) = record_run(path, [changed_text_recording()])
        let assert Ok(player) =
          recorder.new()
          |> directory(path)
          |> mode(recorder.Playback)
          |> start()

        // Act
        let found = recorder.find_recording(player, recorded.text_request())
        let assert Ok(Nil) = recorder.stop(player)

        // Assert
        found
        |> should
        |> be_equal(Ok(Some(changed_text_recording())))
        |> or_fail_with("Playback should give the new response")
      }),
      it("gives a stream the same file name in each record run", fn() {
        // Arrange
        let path = temp_directory.path("replace_stream")
        let assert Ok(Nil) = record_run(path, [stream_recording(1)])

        // Act
        let assert Ok(Nil) = record_run(path, [stream_recording(7)])
        let files = sorted_files(path)

        // Assert
        files
        |> should
        |> be_equal(Ok([stream_file]))
        |> or_fail_with("A stream should keep its file name")
      }),
      it("keeps the recording of a request that the run does not record", fn() {
        // Arrange
        let path = temp_directory.path("replace_partial_run")
        let assert Ok(Nil) = record_run(path, [recorded.text_recording()])

        // Act
        let assert Ok(Nil) = record_run(path, [other_recording()])
        let files = sorted_files(path)

        // Assert
        files
        |> should
        |> be_equal(Ok([other_file, text_file]))
        |> or_fail_with("A partial run should keep the other recordings")
      }),
      it("removes a file with an old name for the same request", fn() {
        // Arrange
        let path = temp_directory.path("replace_old_name")
        let assert Ok(Nil) =
          write_file(path, old_text_file, recorded.text_recording())

        // Act
        let assert Ok(Nil) = record_run(path, [changed_text_recording()])
        let files = sorted_files(path)

        // Assert
        files
        |> should
        |> be_equal(Ok([text_file]))
        |> or_fail_with("The old file of the request should be removed")
      }),
      it("keeps a file with an old name for another request", fn() {
        // Arrange
        let path = temp_directory.path("replace_old_name_other")
        let old_other_file = "GET_localhost__other_b2ba8f_000000.json"
        let assert Ok(Nil) = write_file(path, old_other_file, other_recording())

        // Act
        let assert Ok(Nil) = record_run(path, [recorded.text_recording()])
        let files = sorted_files(path)

        // Assert
        files
        |> should
        |> be_equal(Ok([old_other_file, text_file]))
        |> or_fail_with("The old file of another request should stay")
      }),
      it("keeps the newest of two responses that one run records", fn() {
        // Arrange
        let path = temp_directory.path("replace_same_run")

        // Act
        let assert Ok(Nil) =
          record_run(path, [recorded.text_recording(), changed_text_recording()])
        let loaded = storage.load_recordings(path)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([changed_text_recording()]))
        |> or_fail_with("The newest response should replace the first")
      }),
      it("ignores an old file that is gone before the run records", fn() {
        // Arrange
        let path = temp_directory.path("replace_gone")
        let assert Ok(Nil) =
          write_file(path, old_text_file, recorded.text_recording())
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode(recorder.Record) |> start()
        let assert Ok(Nil) = simplifile.delete(path <> "/" <> old_text_file)

        // Act
        let saved = recorder.add_recording(writer, changed_text_recording())
        let assert Ok(Nil) = recorder.stop(writer)

        // Assert
        saved
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("A file that is already gone needs no removal")
      }),
      it("returns the error when it cannot remove the old file", fn() {
        // Arrange
        let path = temp_directory.path("replace_read_only")
        let assert Ok(Nil) =
          write_file(path, old_text_file, recorded.text_recording())
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode(recorder.Record) |> start()
        let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o555)

        // Act
        let saved = recorder.add_recording(writer, changed_text_recording())
        let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o755)
        let assert Ok(Nil) = recorder.stop(writer)

        // Assert
        saved
        |> should
        |> be_equal(Error(
          "Failed to save recording: Failed to remove recording file "
          <> path
          <> "/"
          <> old_text_file
          <> ": Eacces",
        ))
        |> or_fail_with("A failed removal is the error of add_recording")
      }),
      it("returns an error at start for a file that cannot be decoded", fn() {
        // Arrange
        let path = temp_directory.path("replace_bad_file")
        let assert Ok(Nil) = simplifile.create_directory_all(path)
        let assert Ok(Nil) = simplifile.write(path <> "/bad.json", "{}")
        let builder = recorder.new() |> directory(path) |> mode(recorder.Record)

        // Act
        let started = start(builder) |> result.map(fn(_) { Nil })

        // Assert
        started
        |> should
        |> be_equal(Error(
          "Failed to load recordings in record mode: Failed to decode "
          <> path
          <> "/bad.json: Expected Field, found Nothing at version",
        ))
        |> or_fail_with("A bad file should stop a record run from starting")
      }),
    ]),
  ])
}

// One record run: a record recorder that records `recordings`, then stops.
fn record_run(
  path: String,
  recordings: List(recording.Recording),
) -> Result(Nil, String) {
  use writer <- result.try(
    recorder.new() |> directory(path) |> mode(recorder.Record) |> start(),
  )
  let saved = list.try_each(recordings, recorder.add_recording(writer, _))
  let _stopped = recorder.stop(writer)
  saved
}

// Writes `rec` to `path/name`, the way an older version named its files.
fn write_file(
  path: String,
  name: String,
  rec: recording.Recording,
) -> Result(Nil, simplifile.FileError) {
  let content =
    recording.RecordingFile(version: "1.0", entries: [rec])
    |> recording.encode_recording_file
    |> json.to_string
  use _ <- result.try(simplifile.create_directory_all(path))
  simplifile.write(path <> "/" <> name, content)
}

fn sorted_files(path: String) -> Result(List(String), simplifile.FileError) {
  simplifile.read_directory(path)
  |> result.map(list.sort(_, string.compare))
}

fn changed_text_recording() -> recording.Recording {
  recording.Recording(
    ..recorded.text_recording(),
    response: recorded.ok_response("Changed"),
  )
}

fn other_recording() -> recording.Recording {
  recorded.recording_at("/other", None, "Other")
}

fn stream_recording(delay_ms: Int) -> recording.Recording {
  recording.Recording(
    request: recording.RecordedRequest(
      ..recorded.text_request(),
      path: "/stream",
    ),
    response: recording.StreamingResponse(status: 200, headers: [], chunks: [
      recording.Chunk(data: <<"one">>, delay_ms: delay_ms),
    ]),
  )
}
