//// A recorded call returns only when its recording is on disk. A playback
//// recorder that starts on the same directory at once finds every
//// recording, with no wait and no call to `recorder.stop`.

import dream_http_client/client.{type SendError}
import dream_http_client/matching
import dream_http_client/recorder.{directory, key, mode, start}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import fixtures/temp_directory
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import simplifile

pub fn tests() -> TestSuite {
  describe("dream_http_client/recording on disk", [
    group("a recorded call returns when its recording is on disk", [
      it(
        "a playback recorder started at once finds both POSTs, 100 times in sequence",
        fn() {
          // Arrange
          let first_attempt = 1

          // Act
          let missed =
            int.range(
              from: first_attempt,
              to: 101,
              with: [],
              run: fn(missed, attempt) {
                case record_and_play(attempt) {
                  Ok([201, 201]) -> missed
                  other -> [
                    int.to_string(attempt) <> ": " <> string.inspect(other),
                    ..missed
                  ]
                }
              },
            )

          // Assert
          missed
          |> should
          |> be_equal([])
          |> or_fail_with("Every recording is on disk when send returns")
        },
      ),
    ]),
    group("a failed write is the error of the call", [
      it("send returns the write error", fn() {
        // Arrange
        let request = unwritable_request("on_disk_send")

        // Act
        let value = client.send(request)

        // Assert
        value
        |> should
        |> be_equal(
          Error(
            client.RequestError(
              client.Unexpected(raw: write_error("on_disk_send")),
            ),
          ),
        )
        |> or_fail_with("send gives the write error, not the response")
      }),
      it("stream_yielder ends with the write error", fn() {
        // Arrange
        let request = unwritable_request("on_disk_yielder")

        // Act
        let value =
          client.stream_yielder(request)
          |> yielder.to_list()
          |> list.last()

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            Error(
              client.TransportFailure(
                client.Unexpected(raw: write_error("on_disk_yielder")),
              ),
            ),
          ),
        )
        |> or_fail_with("The last item of the yielder is the write error")
      }),
      it("start_stream gives the write error to on_stream_error", fn() {
        // Arrange
        let errors = process.new_subject()
        let request =
          unwritable_request("on_disk_start_stream")
          |> client.on_stream_error(fn(failure) {
            process.send(errors, failure)
          })

        // Act
        let value =
          client.start_stream(request)
          |> result.map(fn(_handle) { process.receive(errors, 5000) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            Ok(
              client.TransportFailure(
                client.Unexpected(raw: write_error("on_disk_start_stream")),
              ),
            ),
          ),
        )
        |> or_fail_with("The stream ends with the write error")
      }),
    ]),
  ])
}

/// A GET with a record-mode recorder whose directory cannot be created:
/// its parent is a file.
fn unwritable_request(label: String) -> client.ClientRequest {
  let parent = temp_directory.path(label)
  let assert Ok(Nil) = simplifile.create_directory_all(temp_directory.root)
  let assert Ok(Nil) = simplifile.write(parent, "a file, not a directory")
  let assert Ok(recorder_instance) =
    recorder.new()
    |> directory(parent <> "/recordings")
    |> mode(recorder.Record)
    |> start()
  mock_server.get("/text")
  |> client.recorder(recorder_instance)
}

fn write_error(label: String) -> String {
  "Failed to save recording: Failed to create directory "
  <> temp_directory.path(label)
  <> "/recordings: Enotdir"
}

/// Records two POSTs, then at once plays them back from a new playback
/// recorder on the same directory. Gives the statuses of the playback.
fn record_and_play(attempt: Int) -> Result(List(Int), String) {
  let mocks_directory =
    temp_directory.path("recording_on_disk_" <> int.to_string(attempt))
  let recorded =
    start_recorder(mocks_directory, recorder.Record)
    |> result.try(fn(recording_recorder) {
      send_both(recording_recorder)
      |> result.map_error(string.inspect)
    })
  recorded
  |> result.try(fn(_recorded_statuses) {
    start_recorder(mocks_directory, recorder.Playback)
  })
  |> result.try(fn(playback_recorder) {
    send_both(playback_recorder)
    |> result.map_error(string.inspect)
  })
}

fn start_recorder(
  mocks_directory: String,
  recorder_mode: recorder.Mode,
) -> Result(recorder.Recorder, String) {
  recorder.new()
  |> directory(mocks_directory)
  |> mode(recorder_mode)
  |> key(matching.request_key(
    method: True,
    url: True,
    headers: False,
    body: True,
  ))
  |> start()
}

fn send_both(
  recorder_instance: recorder.Recorder,
) -> Result(List(Int), SendError) {
  ["first", "second"]
  |> list.try_map(fn(body) { send_post(recorder_instance, body) })
}

fn send_post(
  recorder_instance: recorder.Recorder,
  body: String,
) -> Result(Int, SendError) {
  mock_server.request(http.Post, "/post")
  |> client.body(body)
  |> client.recorder(recorder_instance)
  |> client.send()
  |> result.map(fn(response) { response.status })
}
