//// Client paths that the other suites do not reach: playback of a blocking
//// recording through start_stream, an empty request path, and a host that
//// is not valid in a URL.

import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import fixtures/recorded
import fixtures/temp_directory
import gleam/erlang/process
import gleam/result

pub fn tests() -> TestSuite {
  describe("edge paths", [
    group("playback through start_stream", [
      it("passes the headers of a blocking recording to on_stream_start", fn() {
        // Arrange
        let path = temp_directory.path("edge_start_playback_headers")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.BlockingResponse(
                status: 200,
                headers: [#("X-Recorded", "yes")],
                body: <<"recorded">>,
              ),
            ),
            "edge",
          )
        let assert Ok(rec) =
          recorder.new()
          |> directory(path)
          |> mode(recorder.Playback)
          |> start()
        let started = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.on_stream_start(fn(headers) {
            process.send(started, headers)
          })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let headers = process.receive(started, 10_000)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        headers
        |> should
        |> be_equal(Ok([client.Header(name: "X-Recorded", value: "yes")]))
        |> or_fail_with("on_stream_start should get the recorded headers")
      }),
    ]),
    group("request URL", [
      it("send uses / for an empty path", fn() {
        // Arrange
        let request = mock_server.get("")

        // Act
        let status = client.send(request) |> result.map(fn(r) { r.status })

        // Assert
        status
        |> should
        |> be_equal(Ok(200))
        |> or_fail_with("An empty path should request the index route")
      }),
      it("send returns an error for a host that is not valid in a URL", fn() {
        // Arrange
        let request = mock_server.get("/text") |> client.host("bad host")

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(
          Error(client.RequestError(client.Unexpected("invalid_uri"))),
        )
        |> or_fail_with("A host with a space should be rejected")
      }),
    ]),
  ])
}
