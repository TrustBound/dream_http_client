//// Tests for the nearest recordings of a playback miss. When no recording
//// matches a request, `NoRecording` names up to three recordings with the
//// same method and path, nearest first, and the parts that the key
//// compares and that differ. `transport_error_to_string` shows them.
////
//// A miss sends nothing to the network, so the port of the requests needs
//// no server.

import dream_http_client/client.{NoRecording, RequestError, Unexpected}
import dream_http_client/matching
import dream_http_client/recorder.{
  Body, Difference, Header, NearestRecording, Origin, Query, directory, mode,
  start,
}
import dream_http_client/recording.{
  type RecordedRequest, BlockingResponse, RecordedRequest, Recording,
}
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/temp_directory
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub fn tests() -> TestSuite {
  describe("the nearest recordings of a playback miss", [
    group("one changed query parameter", [
      it("the text shows the query diff", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_query_text")
        save(dir, oslo(Some("units=imperial")), "imperial")
        let playback = playback(dir)

        // Act
        let text =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/oslo?units=metric\n"
          <> "Nearest recording: build/test_tmp/nearest_query_text/GET_localhost__v1_forecast_oslo_3a5b8990e60ffa74.json\n"
          <> "  query:\n"
          <> "  - units=imperial\n"
          <> "  + units=metric",
        )
        |> or_fail_with("The miss should show the changed query")
      }),
      it("the typed error holds the recording and the difference", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_query_typed")
        save(dir, oslo(Some("units=imperial")), "imperial")
        let playback = playback(dir)

        // Act
        let error =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss()

        // Assert
        error
        |> should
        |> be_equal(
          NoRecording(
            method: "GET",
            url: "http://localhost:19801/v1/forecast/oslo?units=metric",
            directory: "build/test_tmp/nearest_query_typed",
            nearest: [
              NearestRecording(
                path: "build/test_tmp/nearest_query_typed/GET_localhost__v1_forecast_oslo_3a5b8990e60ffa74.json",
                differences: [
                  Difference(
                    part: Query,
                    recorded: Some("units=imperial"),
                    requested: Some("units=metric"),
                  ),
                ],
              ),
            ],
          ),
        )
        |> or_fail_with("The miss should hold the nearest recording")
      }),
    ]),
    group("several candidates", [
      it("are ordered nearest first and capped at three", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_order")
        save(dir, full("application/json", [], "{\"days\":3}"), "one")
        save(dir, full("text/plain", [], "{\"days\":3}"), "two")
        save(dir, full("text/plain", [], "{\"days\":5}"), "three")
        save(
          dir,
          full("text/plain", [#("x-trace", "1")], "{\"days\":5}"),
          "four",
        )
        let playback = playback_with_full_key(dir)

        // Act
        let paths =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.add_header("accept", "application/json")
          |> client.body("{\"days\":3}")
          |> client.recorder(playback)
          |> miss()
          |> nearest_paths()

        // Assert
        paths
        |> should
        |> be_equal([
          "build/test_tmp/nearest_order/GET_localhost__v1_forecast_oslo_7692c3ad3540bb80.json",
          "build/test_tmp/nearest_order/GET_localhost__v1_forecast_oslo_3fc4ccfe745870e2.json",
          "build/test_tmp/nearest_order/GET_localhost__v1_forecast_oslo_8b5b9db0c13db242.json",
        ])
        |> or_fail_with("Fewest differences first, at most three")
      }),
      it("with the same number of differences are ordered by path", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_tie")
        save(dir, oslo(Some("units=kelvin")), "tie_b")
        save(dir, oslo(Some("units=imperial")), "tie_a")
        let playback = playback(dir)

        // Act
        let paths =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss()
          |> nearest_paths()

        // Assert
        paths
        |> should
        |> be_equal([
          "build/test_tmp/nearest_tie/GET_localhost__v1_forecast_oslo_a95478d7e57e9896.json",
          "build/test_tmp/nearest_tie/GET_localhost__v1_forecast_oslo_f620a804b823fa88.json",
        ])
        |> or_fail_with("A tie should keep the order of the paths")
      }),
      it("the text shows each candidate with its differences", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_text_many")
        save(dir, full("application/json", [], "{\"days\":3}"), "one")
        save(
          dir,
          full("text/plain", [#("x-trace", "1")], "{\"days\":3}"),
          "two",
        )
        let playback = playback_with_full_key(dir)

        // Act
        let text =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.add_header("accept", "application/json")
          |> client.body("{\"days\":3}")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/oslo?units=metric\n"
          <> "Nearest recording: build/test_tmp/nearest_text_many/GET_localhost__v1_forecast_oslo_7692c3ad3540bb80.json\n"
          <> "  query:\n"
          <> "  - units=imperial\n"
          <> "  + units=metric\n"
          <> "Next nearest recording: build/test_tmp/nearest_text_many/GET_localhost__v1_forecast_oslo_3fc4ccfe745870e2.json\n"
          <> "  query:\n"
          <> "  - units=imperial\n"
          <> "  + units=metric\n"
          <> "  header accept:\n"
          <> "  - text/plain\n"
          <> "  + application/json\n"
          <> "  header x-trace:\n"
          <> "  - 1\n"
          <> "  + (none)",
        )
        |> or_fail_with("Each candidate should show its own differences")
      }),
    ]),
    group("the parts that differ", [
      it("a header that the key does not compare is not shown", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_header_ignored")
        save(
          dir,
          RecordedRequest(..oslo(Some("units=imperial")), headers: [
            #("accept", "text/plain"),
          ]),
          "header",
        )
        let playback = playback(dir)

        // Act
        let differences =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.add_header("accept", "application/json")
          |> client.recorder(playback)
          |> miss()
          |> nearest_differences()

        // Assert
        differences
        |> should
        |> be_equal([
          [
            Difference(
              part: Query,
              recorded: Some("units=imperial"),
              requested: Some("units=metric"),
            ),
          ],
        ])
        |> or_fail_with("The default key does not compare headers")
      }),
      it("a different port shows the origin", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_origin")
        save(
          dir,
          RecordedRequest(..oslo(Some("units=metric")), port: Some(19_802)),
          "port",
        )
        let playback = playback(dir)

        // Act
        let text =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/oslo?units=metric\n"
          <> "Nearest recording: build/test_tmp/nearest_origin/GET_localhost__v1_forecast_oslo_f8d397a33fcb9725.json\n"
          <> "  origin:\n"
          <> "  - http://localhost:19802\n"
          <> "  + http://localhost:19801",
        )
        |> or_fail_with("The miss should show the other port")
      }),
      it("a body that is not text shows as base64, and no body as none", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_body")
        save(
          dir,
          RecordedRequest(..oslo(Some("units=metric")), body: <<0, 255>>),
          "binary",
        )
        let playback = playback_with_full_key(dir)

        // Act
        let differences =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss()
          |> nearest_differences()

        // Assert
        differences
        |> should
        |> be_equal([
          [
            Difference(
              part: Body,
              recorded: Some("base64:AP8="),
              requested: None,
            ),
          ],
        ])
        |> or_fail_with("The body should show as base64")
      }),
      it("a header in the key shows with its name", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_header_typed")
        save(dir, full("text/plain", [], ""), "header")
        let playback = playback_with_full_key(dir)

        // Act
        let differences =
          forecast("/v1/forecast/oslo", "units=imperial")
          |> client.add_header("accept", "application/json")
          |> client.recorder(playback)
          |> miss()
          |> nearest_differences()

        // Assert
        differences
        |> should
        |> be_equal([
          [
            Difference(
              part: Header("accept"),
              recorded: Some("text/plain"),
              requested: Some("application/json"),
            ),
          ],
        ])
        |> or_fail_with("The header should show with its name")
      }),
      it("the origin is a typed part", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_origin_typed")
        save(
          dir,
          RecordedRequest(..oslo(Some("units=metric")), port: Some(19_802)),
          "port",
        )
        let playback = playback(dir)

        // Act
        let differences =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss()
          |> nearest_differences()

        // Assert
        differences
        |> should
        |> be_equal([
          [
            Difference(
              part: Origin,
              recorded: Some("http://localhost:19802"),
              requested: Some("http://localhost:19801"),
            ),
          ],
        ])
        |> or_fail_with("The origin should be a typed part")
      }),
      it("a changed text body shows in the text", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_body_text")
        save(dir, full("application/json", [], "{\"days\":5}"), "body")
        let playback = playback_with_full_key(dir)

        // Act
        let text =
          forecast("/v1/forecast/oslo", "units=imperial")
          |> client.add_header("accept", "application/json")
          |> client.body("{\"days\":3}")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/oslo?units=imperial\n"
          <> "Nearest recording: build/test_tmp/nearest_body_text/GET_localhost__v1_forecast_oslo_230d8358dc8e8890.json\n"
          <> "  body:\n"
          <> "  - {\"days\":5}\n"
          <> "  + {\"days\":3}",
        )
        |> or_fail_with("The miss should show the changed body")
      }),
      it("a request with no port shows an origin with no port", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_origin_no_port")
        save(dir, oslo(Some("units=metric")), "port")
        let playback = playback(dir)

        // Act
        let differences =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("localhost")
          |> client.path("/v1/forecast/oslo")
          |> client.query("units=metric")
          |> client.recorder(playback)
          |> miss()
          |> nearest_differences()

        // Assert
        differences
        |> should
        |> be_equal([
          [
            Difference(
              part: Origin,
              recorded: Some("http://localhost:19801"),
              requested: Some("http://localhost"),
            ),
          ],
        ])
        |> or_fail_with("The origin should have no port")
      }),
    ]),
    group("scrubbed values", [
      it("the text shows the request after the request transformer", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_scrubbed_text")
        save(dir, oslo(Some("token=scrubbed&units=imperial")), "scrubbed")
        let playback = scrubbing_playback(dir)

        // Act
        let text =
          forecast("/v1/forecast/oslo", "token=hunter2&units=metric")
          |> client.add_header("authorization", "Bearer hunter2")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/oslo?token=scrubbed&units=metric\n"
          <> "Nearest recording: build/test_tmp/nearest_scrubbed_text/GET_localhost__v1_forecast_oslo_4848b001e417e751.json\n"
          <> "  query:\n"
          <> "  - token=scrubbed&units=imperial\n"
          <> "  + token=scrubbed&units=metric",
        )
        |> or_fail_with("The miss should show only scrubbed values")
      }),
      it("the text never holds a value that the transformer removes", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_scrubbed_secret")
        save(dir, oslo(Some("token=scrubbed&units=imperial")), "scrubbed")
        let playback = scrubbing_playback(dir)

        // Act
        let has_secret =
          forecast("/v1/forecast/oslo", "token=hunter2&units=metric")
          |> client.add_header("authorization", "Bearer hunter2")
          |> client.recorder(playback)
          |> miss_text()
          |> string.contains("hunter2")

        // Assert
        has_secret
        |> should
        |> be_equal(False)
        |> or_fail_with("A scrubbed secret must not show")
      }),
    ]),
    group("no candidate", [
      it("the text names the directory it searched", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_none_text")
        save(dir, oslo(Some("units=imperial")), "imperial")
        let playback = playback(dir)

        // Act
        let text =
          forecast("/v1/forecast/bergen", "units=metric")
          |> client.recorder(playback)
          |> miss_text()

        // Assert
        text
        |> should
        |> be_equal(
          "No recording matches GET http://localhost:19801/v1/forecast/bergen?units=metric\n"
          <> "No recording in build/test_tmp/nearest_none_text has this method and path",
        )
        |> or_fail_with("The miss should name the directory it searched")
      }),
      it("a recording with another method is not a candidate", fn() {
        // Arrange
        let dir = temp_directory.path("nearest_none_method")
        save(
          dir,
          RecordedRequest(..oslo(Some("units=metric")), method: http.Post),
          "imperial",
        )
        let playback = playback(dir)

        // Act
        let paths =
          forecast("/v1/forecast/oslo", "units=metric")
          |> client.recorder(playback)
          |> miss()
          |> nearest_paths()

        // Assert
        paths
        |> should
        |> be_equal([])
        |> or_fail_with("Only the same method and path are candidates")
      }),
    ]),
    group("the recorder", [
      it("playback_miss of a stopped recorder is None", fn() {
        // Arrange
        let playback = playback(temp_directory.path("nearest_stopped"))
        let assert Ok(Nil) = recorder.stop(playback)

        // Act
        let value = recorder.playback_miss(playback, oslo(None))

        // Assert
        value
        |> should
        |> be_equal(None)
        |> or_fail_with("A stopped recorder explains no miss")
      }),
    ]),
  ])
}

/// A GET of `path` on localhost:19801 with a query, and no recorder yet.
fn forecast(path: String, query: String) -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(19_801)
  |> client.path(path)
  |> client.query(query)
}

/// The recorded GET of /v1/forecast/oslo with a query.
fn oslo(query: option.Option(String)) -> RecordedRequest {
  RecordedRequest(
    method: http.Get,
    scheme: http.Http,
    host: "localhost",
    port: Some(19_801),
    path: "/v1/forecast/oslo",
    query: query,
    headers: [],
    body: <<>>,
  )
}

/// The recorded GET of /v1/forecast/oslo?units=imperial with an accept
/// header, more headers and a body.
fn full(
  accept: String,
  more_headers: List(#(String, String)),
  body: String,
) -> RecordedRequest {
  RecordedRequest(
    ..oslo(Some("units=imperial")),
    headers: [#("accept", accept), ..more_headers],
    body: <<body:utf8>>,
  )
}

/// Writes a recording of `request` to a file named from `label`.
fn save(dir: String, request: RecordedRequest, label: String) -> Nil {
  let response = BlockingResponse(status: 200, headers: [], body: <<"ok">>)
  let assert Ok(Nil) =
    storage.save_recording_immediately(
      dir,
      Recording(request: request, response: response),
      label,
    )
  Nil
}

fn playback(dir: String) -> recorder.Recorder {
  let assert Ok(rec) =
    recorder.new() |> directory(dir) |> mode(recorder.Playback) |> start()
  rec
}

fn playback_with_full_key(dir: String) -> recorder.Recorder {
  let assert Ok(rec) =
    recorder.new()
    |> directory(dir)
    |> mode(recorder.Playback)
    |> recorder.key(matching.request_key(
      method: True,
      url: True,
      headers: True,
      body: True,
    ))
    |> start()
  rec
}

/// A playback recorder whose key compares headers, and whose request
/// transformer drops the authorization header and scrubs the token.
fn scrubbing_playback(dir: String) -> recorder.Recorder {
  let assert Ok(rec) =
    recorder.new()
    |> directory(dir)
    |> mode(recorder.Playback)
    |> recorder.key(matching.request_key(
      method: True,
      url: True,
      headers: True,
      body: False,
    ))
    |> recorder.request_transformer(scrub)
    |> start()
  rec
}

fn scrub(request: RecordedRequest) -> RecordedRequest {
  RecordedRequest(
    ..request,
    headers: list.filter(request.headers, fn(header) {
      header.0 != "authorization"
    }),
    query: option.map(request.query, string.replace(
      _,
      "token=hunter2",
      "token=scrubbed",
    )),
  )
}

fn miss(request: client.ClientRequest) -> client.TransportError {
  case client.send(request) {
    Error(RequestError(error: error)) -> error
    _ -> Unexpected(raw: "The request did not miss")
  }
}

fn miss_text(request: client.ClientRequest) -> String {
  client.transport_error_to_string(miss(request))
}

fn nearest_paths(error: client.TransportError) -> List(String) {
  case error {
    NoRecording(nearest: nearest, ..) ->
      list.map(nearest, fn(candidate) { candidate.path })
    _ -> []
  }
}

fn nearest_differences(
  error: client.TransportError,
) -> List(List(recorder.Difference)) {
  case error {
    NoRecording(nearest: nearest, ..) ->
      list.map(nearest, fn(candidate) { candidate.differences })
    _ -> []
  }
}
