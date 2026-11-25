import dream_http_client/matching
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recorded
import fixtures/temp_directory
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile

pub fn tests() -> TestSuite {
  describe("dream_http_client/storage", [
    group("load_recordings", [
      it("returns an empty list for a missing directory", fn() {
        // Arrange
        let directory = temp_directory.path("storage_missing")

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([]))
        |> or_fail_with("A missing directory should hold no recordings")
      }),
      it("loads the committed fixture", fn() {
        // Arrange
        let directory = "test/fixtures/api"

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(
          Ok([
            recording.Recording(
              request: recorded.text_request(),
              response: recording.BlockingResponse(
                status: 200,
                headers: [#("Content-Type", "text/plain")],
                body: <<"Recorded text from the fixture">>,
              ),
            ),
          ]),
        )
        |> or_fail_with("The committed fixture should load")
      }),
      it("returns an error when the directory is a file", fn() {
        // Arrange
        let directory = temp_directory.path("storage_load_file")
        let assert Ok(Nil) =
          simplifile.create_directory_all(temp_directory.root)
        let assert Ok(Nil) = simplifile.write(directory, "not a directory")

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Error(
          "Failed to read directory " <> directory <> ": Enotdir",
        ))
        |> or_fail_with("A file in place of the directory should be an error")
      }),
      it("returns an error for a .json entry that cannot be read", fn() {
        // Arrange
        let directory = temp_directory.path("storage_load_unreadable")
        let assert Ok(Nil) =
          simplifile.create_directory_all(directory <> "/folder.json")

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Error(
          "Failed to read " <> directory <> "/folder.json: Eisdir",
        ))
        |> or_fail_with("An unreadable file should be an error")
      }),
      it("returns an error for a file that is not JSON", fn() {
        // Arrange
        let directory = temp_directory.path("storage_load_invalid")
        let assert Ok(Nil) = simplifile.create_directory_all(directory)
        let assert Ok(Nil) = simplifile.write(directory <> "/bad.json", "nope")

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Error(
          "Failed to decode "
          <> directory
          <> "/bad.json: Unexpected end of JSON input",
        ))
        |> or_fail_with("A file that is not JSON should be an error")
      }),
      it("returns an error for a file with no entries", fn() {
        // Arrange
        let directory = temp_directory.path("storage_load_empty")
        let assert Ok(Nil) = simplifile.create_directory_all(directory)
        let assert Ok(Nil) =
          simplifile.write(
            directory <> "/empty.json",
            "{\"version\":\"1.0\",\"entries\":[]}",
          )

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Error(
          "Recording file contains no entries: " <> directory <> "/empty.json",
        ))
        |> or_fail_with("A file with no entries should be an error")
      }),
      it("ignores files that do not end in .json", fn() {
        // Arrange
        let directory = temp_directory.path("storage_load_other_files")
        let assert Ok(Nil) = simplifile.create_directory_all(directory)
        let assert Ok(Nil) = simplifile.write(directory <> "/notes.txt", "x")

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([]))
        |> or_fail_with("Files that are not .json should be ignored")
      }),
    ]),
    group("save_recordings", [
      it("saves a recording that load_recordings reads back", fn() {
        // Arrange
        let directory = temp_directory.path("storage_save_one")
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording()],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )

        // Act
        let loaded = storage.load_recordings(directory)

        // Assert
        loaded
        |> should
        |> be_equal(Ok([recorded.text_recording()]))
        |> or_fail_with("The saved recording should load")
      }),
      it("saves every recording", fn() {
        // Arrange
        let directory = temp_directory.path("storage_save_many")
        let second = recorded.recording_at("/stream", None, "Stream response")
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording(), second],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )

        // Act
        let loaded =
          storage.load_recordings(directory)
          |> result.map(
            list.sort(_, fn(a, b) {
              string.compare(a.request.path, b.request.path)
            }),
          )

        // Assert
        loaded
        |> should
        |> be_equal(Ok([second, recorded.text_recording()]))
        |> or_fail_with("Both recordings should load")
      }),
      it("names the file method, host, path and key hash", fn() {
        // Arrange
        let directory = temp_directory.path("storage_filename")

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording()],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )
        let files = simplifile.read_directory(directory)

        // Assert
        files
        |> should
        |> be_equal(Ok(["GET_localhost__text_7646ad0d38469745.json"]))
        |> or_fail_with("Exactly one file, with no temp file, should exist")
      }),
      it("writes a file per query string", fn() {
        // Arrange
        let directory = temp_directory.path("storage_query")
        let first = recorded.recording_at("/text", Some("a=1"), "Hello, World!")
        let second =
          recorded.recording_at("/text", Some("a=2"), "Hello, World!")

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [first, second],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )
        let files =
          simplifile.read_directory(directory)
          |> result.map(list.sort(_, string.compare))

        // Assert
        files
        |> should
        |> be_equal(
          Ok([
            "GET_localhost__text_21a3ff746b7bd35d.json",
            "GET_localhost__text_2c2b6dfe41ad69d3.json",
          ]),
        )
        |> or_fail_with("Each query string should get its own file")
      }),
      it("overwrites the file of the same request", fn() {
        // Arrange
        let directory = temp_directory.path("storage_overwrite")

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording(), recorded.text_recording()],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )
        let files = simplifile.read_directory(directory)

        // Assert
        files
        |> should
        |> be_equal(Ok(["GET_localhost__text_7646ad0d38469745.json"]))
        |> or_fail_with("The same request should give one file")
      }),
      it("replaces characters that are not safe in a file name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_sanitize")
        let unsafe =
          recorded.recording_at("/api/users?id=1&x=y z", None, "Hello, World!")

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [unsafe],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )
        let files = simplifile.read_directory(directory)

        // Assert
        files
        |> should
        |> be_equal(
          Ok(["GET_localhost__api_users_id_1_x_y_z_4d99aecb2ef1703d.json"]),
        )
        |> or_fail_with("Unsafe characters should become underscores")
      }),
      it("cuts the path part of the name to 50 characters", fn() {
        // Arrange
        let directory = temp_directory.path("storage_long_path")
        let long =
          recorded.recording_at(
            "/api/v1/users/12345/profile/settings/notifications/preferences/email/weekly",
            None,
            "Hello, World!",
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [long],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )
        let files = simplifile.read_directory(directory)

        // Assert
        files
        |> should
        |> be_equal(
          Ok([
            "GET_localhost__api_v1_users_12345_profile_settings_notifications_86514a2edbe09165.json",
          ]),
        )
        |> or_fail_with("The path part should be cut to 50 characters")
      }),
      it("uses the key function for the key hash", fn() {
        // Arrange
        let directory = temp_directory.path("storage_key_hash")
        let method_only =
          matching.request_key(
            method: True,
            url: False,
            headers: False,
            body: False,
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording()],
            method_only,
          )
        let files = simplifile.read_directory(directory)

        // Assert
        files
        |> should
        |> be_equal(Ok(["GET_localhost__text_14e30cd163c73291.json"]))
        |> or_fail_with("The key hash should come from the key function")
      }),
      it("uses the uppercase name of an Other method", fn() {
        // Arrange
        let directory = temp_directory.path("storage_other_method")
        let purge =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Other("purge"),
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, purge, "k")
        let files =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 21)))

        // Assert
        files
        |> should
        |> be_equal(Ok(["PURGE_localhost__text"]))
        |> or_fail_with("The method part should be PURGE")
      }),
      it("returns an error when the directory cannot be made", fn() {
        // Arrange
        let blocker = temp_directory.path("storage_save_blocker")
        let assert Ok(Nil) =
          simplifile.create_directory_all(temp_directory.root)
        let assert Ok(Nil) = simplifile.write(blocker, "a file")
        let directory = blocker <> "/inside"

        // Act
        let saved =
          storage.save_recordings(
            directory,
            [recorded.text_recording()],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )

        // Assert
        saved
        |> should
        |> be_equal(Error(
          "Failed to create directory " <> directory <> ": Enotdir",
        ))
        |> or_fail_with("A file in the path should stop the save")
      }),
    ]),
    group("method part of the file name", [
      it("uses POST as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_post")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Post,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 20)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["POST_localhost__text"]))
        |> or_fail_with("The method part should be POST")
      }),
      it("uses PUT as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_put")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Put,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 19)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["PUT_localhost__text"]))
        |> or_fail_with("The method part should be PUT")
      }),
      it("uses DELETE as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_delete")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Delete,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 22)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["DELETE_localhost__text"]))
        |> or_fail_with("The method part should be DELETE")
      }),
      it("uses PATCH as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_patch")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Patch,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 21)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["PATCH_localhost__text"]))
        |> or_fail_with("The method part should be PATCH")
      }),
      it("uses HEAD as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_head")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Head,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 20)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["HEAD_localhost__text"]))
        |> or_fail_with("The method part should be HEAD")
      }),
      it("uses OPTIONS as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_options")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Options,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 23)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["OPTIONS_localhost__text"]))
        |> or_fail_with("The method part should be OPTIONS")
      }),
      it("uses TRACE as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_trace")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Trace,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 21)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["TRACE_localhost__text"]))
        |> or_fail_with("The method part should be TRACE")
      }),
      it("uses CONNECT as the method part of the name", fn() {
        // Arrange
        let directory = temp_directory.path("storage_method_connect")
        let entry =
          recording.Recording(
            ..recorded.text_recording(),
            request: recording.RecordedRequest(
              ..recorded.text_request(),
              method: http.Connect,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(directory, entry, "k")
        let value =
          simplifile.read_directory(directory)
          |> result.map(list.map(_, string.slice(_, 0, 23)))

        // Assert
        value
        |> should
        |> be_equal(Ok(["CONNECT_localhost__text"]))
        |> or_fail_with("The method part should be CONNECT")
      }),
    ]),
    group("save_recording_immediately", [
      it("adds a recording next to the saved ones", fn() {
        // Arrange
        let directory = temp_directory.path("storage_immediate")
        let second = recorded.recording_at("/stream", None, "Stream response")
        let assert Ok(Nil) =
          storage.save_recordings(
            directory,
            [recorded.text_recording()],
            matching.request_key(
              method: True,
              url: True,
              headers: False,
              body: False,
            ),
          )

        // Act
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            directory,
            second,
            "GEThttp://localhost:9876/stream",
          )
        let loaded =
          storage.load_recordings(directory)
          |> result.map(
            list.sort(_, fn(a, b) {
              string.compare(a.request.path, b.request.path)
            }),
          )

        // Assert
        loaded
        |> should
        |> be_equal(Ok([second, recorded.text_recording()]))
        |> or_fail_with("Both recordings should load")
      }),
      it("returns an error when the directory cannot be made", fn() {
        // Arrange
        let blocker = temp_directory.path("storage_immediate_blocker")
        let assert Ok(Nil) =
          simplifile.create_directory_all(temp_directory.root)
        let assert Ok(Nil) = simplifile.write(blocker, "a file")
        let directory = blocker <> "/inside"

        // Act
        let saved =
          storage.save_recording_immediately(
            directory,
            recorded.text_recording(),
            "k",
          )

        // Assert
        saved
        |> should
        |> be_equal(Error(
          "Failed to create directory " <> directory <> ": Enotdir",
        ))
        |> or_fail_with("A file in the path should stop the save")
      }),
      it("returns an error when the directory cannot be written", fn() {
        // Arrange
        let directory = temp_directory.path("storage_immediate_read_only")
        let assert Ok(Nil) = simplifile.create_directory_all(directory)
        let assert Ok(Nil) = simplifile.set_permissions_octal(directory, 0o555)

        // Act
        let saved =
          storage.save_recording_immediately(
            directory,
            recorded.text_recording(),
            "GEThttp://localhost:9876/text",
          )

        // Assert
        saved
        |> should
        |> be_equal(Error(
          "Failed to write recording file "
          <> directory
          <> "/GET_localhost__text_7646ad0d38469745.json: \"eacces\"",
        ))
        |> or_fail_with("A read-only directory should stop the write")
      }),
      it("returns an error when the target name is a folder", fn() {
        // Arrange
        let directory = temp_directory.path("storage_immediate_rename")
        let target = directory <> "/GET_localhost__text_7646ad0d38469745.json"
        let assert Ok(Nil) = simplifile.create_directory_all(target)
        let assert Ok(Nil) = simplifile.write(target <> "/keep", "x")

        // Act
        let saved =
          storage.save_recording_immediately(
            directory,
            recorded.text_recording(),
            "GEThttp://localhost:9876/text",
          )

        // Assert
        saved
        |> should
        |> be_equal(Error(
          "Failed to write recording file " <> target <> ": \"eisdir\"",
        ))
        |> or_fail_with("A folder at the target name should stop the rename")
      }),
    ]),
  ])
}
