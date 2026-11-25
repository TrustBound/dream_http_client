//// Tests for the snippets of the request matching guide
//// (docs/guides/request-matching-and-scrubbing.md). Each test records real
//// requests into its own directory, stops the recorder, and plays them
//// back, and asserts the exact value that the guide shows. The output that
//// the guide shows in a `text` block is a file in `test/outputs/`, and the
//// tests compare it with the real output.

import dream_http_client/client
import dream_http_client/matching
import dream_http_client/recorder
import dream_http_client/recording.{BlockingResponse, RecordedRequest, Recording}
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import fixtures/output_file
import fixtures/shown
import fixtures/temp_directory
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import snippets/guide_matching_body_key.{start_search_recorder}
import snippets/guide_matching_scrub.{start_scrubbing_recorder}

pub fn tests() -> TestSuite {
  describe("request matching guide", [
    group("step 1: the default key", [
      it("the default key and a key with the body", fn() {
        // Arrange
        let default_key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: False,
          )
        let body_key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: True,
          )

        // Act
        let lines = [
          "request_key(method: True, url: True, headers: False, body: False)   -> "
            <> string.inspect(default_key(search_request("milk"))),
          "request_key(method: True, url: True, headers: False, body: True)    -> "
            <> string.inspect(body_key(search_request("milk"))),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_matching_keys"))
        |> or_fail_with("The key joins the method, the URL and the body")
      }),
    ]),
    group("step 2: a key with the body", [
      it("each body plays back its own answer", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_body")
        record_two_searches(recordings)
        let assert Ok(playback) =
          start_search_recorder(recorder.Playback, recordings)

        // Act
        let lines =
          list.map(["milk", "eggs"], fn(words) {
            let body = body_text(post_search(words, playback))
            "search " <> string.inspect(words) <> " -> " <> body
          })

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_matching_body_key"))
        |> or_fail_with("Each body should find its recording")
      }),
      it("the default key finds two recordings and refuses", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_ambiguous")
        record_two_searches(recordings)
        let assert Ok(playback) =
          recorder.new()
          |> recorder.directory(recordings)
          |> recorder.mode(recorder.Playback)
          |> recorder.start()

        // Act
        let result =
          post_search("eggs", playback) |> result.map(fn(r) { r.status })

        // Assert
        output_file.lines([string.inspect(result)])
        |> should
        |> be_equal(output_file.read("guide_matching_ambiguous"))
        |> or_fail_with("Two different answers for one key is an error")
      }),
    ]),
    group("steps 3 and 4: scrubbing", [
      it("a recorded header keeps the case of add_header", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_header_case")
        use port <- edge_server.with("set_cookie")
        let assert Ok(plain) =
          recorder.new()
          |> recorder.directory(recordings)
          |> recorder.mode(recorder.Record)
          |> recorder.start()
        let _response =
          session_request(port, "test-token-123")
          |> client.recorder(plain)
          |> client.send()
        let assert Ok(Nil) = recorder.stop(plain)

        // Act
        let headers =
          storage.load_recordings(recordings)
          |> result.map(list.map(_, fn(saved) { saved.request.headers }))

        // Assert
        headers
        |> should
        |> be_equal(Ok([[#("Authorization", "Bearer test-token-123")]]))
        |> or_fail_with("The name keeps its capital letters")
      }),
      it("the request transformer keeps the token out of the file", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_file")
        use port <- edge_server.with("set_cookie")
        record_session(recordings, port)
        let assert Ok(playback) =
          start_scrubbing_recorder(recorder.Playback, recordings)

        // Act
        let lines = [
          "the saved file contains \"test-token-123\"         -> "
            <> files_contain(recordings, "test-token-123"),
          "playback with Authorization: Bearer other-token  -> "
            <> shown.sent(
            session_request(port, "other-token")
            |> client.recorder(playback)
            |> client.send(),
          ),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_matching_request_scrub"))
        |> or_fail_with("The token is not saved and not part of the key")
      }),
      it("the response transformer keeps the cookie out of the file", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_cookie")
        use port <- edge_server.with("set_cookie")
        let assert Ok(scrubbing) =
          start_scrubbing_recorder(recorder.Record, recordings)
        let live =
          session_request(port, "test-token-123")
          |> client.recorder(scrubbing)
          |> client.send()
        let assert Ok(Nil) = recorder.stop(scrubbing)
        let assert Ok(playback) =
          start_scrubbing_recorder(recorder.Playback, recordings)

        // Act
        let lines = [
          "the response your code gets while recording   -> "
            <> response_headers(live),
          "the saved file contains \"session=abc123\"      -> "
            <> files_contain(recordings, "session=abc123"),
          "playback of the recording                       -> "
            <> response_headers_and_body(
            session_request(port, "test-token-123")
            |> client.recorder(playback)
            |> client.send(),
          ),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_matching_response_scrub"))
        |> or_fail_with("Scrubbing changes only what is saved")
      }),
      it("the response transformer does not run in playback", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_playback_cookie")
        let with_cookie =
          Recording(
            request: RecordedRequest(
              method: http.Get,
              scheme: http.Http,
              host: "localhost",
              port: Some(9876),
              path: "/session",
              query: None,
              headers: [],
              body: <<>>,
            ),
            response: BlockingResponse(
              status: 200,
              headers: [#("set-cookie", "session=abc123")],
              body: <<"ok">>,
            ),
          )
        let key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: False,
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            recordings,
            with_cookie,
            key(with_cookie.request),
          )
        let assert Ok(playback) =
          start_scrubbing_recorder(recorder.Playback, recordings)

        // Act
        let headers =
          session_request(9876, "test-token-123")
          |> client.recorder(playback)
          |> client.send()
          |> result.map(fn(response) { response.headers })

        // Assert
        headers
        |> should
        |> be_equal(Ok([client.Header("set-cookie", "session=abc123")]))
        |> or_fail_with("Playback returns the file as it is")
      }),
    ]),
  ])
}

fn search_request(words: String) -> recording.RecordedRequest {
  RecordedRequest(
    method: http.Post,
    scheme: http.Http,
    host: "localhost",
    port: Some(9876),
    path: "/search",
    query: None,
    headers: [#("authorization", "Bearer test-token-123")],
    body: <<words:utf8>>,
  )
}

fn post_search(
  words: String,
  with: recorder.Recorder,
) -> Result(client.HttpResponse, client.SendError) {
  mock_server.request(http.Post, "/post")
  |> client.body(words)
  |> client.recorder(with)
  |> client.send()
}

fn record_two_searches(recordings: String) -> Nil {
  let assert Ok(recording) = start_search_recorder(recorder.Record, recordings)
  let _milk = post_search("milk", recording)
  let _eggs = post_search("eggs", recording)
  let assert Ok(Nil) = recorder.stop(recording)
  Nil
}

fn session_request(port: Int, token: String) -> client.ClientRequest {
  edge_server.request(port)
  |> client.port(port)
  |> client.path("/session")
  |> client.add_header("Authorization", "Bearer " <> token)
}

fn record_session(recordings: String, port: Int) -> Nil {
  let assert Ok(scrubbing) =
    start_scrubbing_recorder(recorder.Record, recordings)
  let _response =
    session_request(port, "test-token-123")
    |> client.recorder(scrubbing)
    |> client.send()
  let assert Ok(Nil) = recorder.stop(scrubbing)
  Nil
}

/// `"yes"` when a recording file in `recordings` contains `text`, and
/// `"no"` when none does.
fn files_contain(recordings: String, text: String) -> String {
  let found =
    simplifile.read_directory(recordings)
    |> result.unwrap([])
    |> list.any(fn(file) {
      simplifile.read(recordings <> "/" <> file)
      |> result.map(string.contains(_, text))
      |> result.unwrap(False)
    })
  case found {
    True -> "yes"
    False -> "no"
  }
}

/// The headers of a response, as `headers name: value, name: value`.
fn response_headers(
  sent: Result(client.HttpResponse, client.SendError),
) -> String {
  case sent {
    Ok(response) ->
      "headers "
      <> string.join(
        list.map(response.headers, fn(header) {
          header.name <> ": " <> header.value
        }),
        ", ",
      )
    Error(_) -> string.inspect(sent)
  }
}

/// The headers and the body of a response.
fn response_headers_and_body(
  sent: Result(client.HttpResponse, client.SendError),
) -> String {
  response_headers(sent) <> ", body " <> string.inspect(body_text(sent))
}

/// The body of a response as text, or `""`.
fn body_text(sent: Result(client.HttpResponse, client.SendError)) -> String {
  sent
  |> result.map(fn(response) { client.body_text(response) |> result.unwrap("") })
  |> result.unwrap("")
}
