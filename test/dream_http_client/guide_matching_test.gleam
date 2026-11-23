//// Tests for the snippets of the request matching guide
//// (docs/guides/request-matching-and-scrubbing.md). Each test records real
//// requests into its own directory, stops the recorder, and plays them
//// back, and asserts the exact value that the guide shows.

import dream_http_client/client.{RequestError, Unexpected}
import dream_http_client/matching
import dream_http_client/recorder
import dream_http_client/recording.{BlockingResponse, RecordedRequest, Recording}
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import fixtures/temp_directory
import gleam/http
import gleam/int
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
      it("the default key is the method and the URL", fn() {
        // Arrange
        let key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: False,
          )

        // Act
        let signature = key(search_request("milk"))

        // Assert
        signature
        |> should
        |> be_equal("POSThttp://localhost:9876/search")
        |> or_fail_with("The key joins the method and the URL")
      }),
      it("a key with the body adds the body", fn() {
        // Arrange
        let key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: True,
          )

        // Act
        let signature = key(search_request("milk"))

        // Assert
        signature
        |> should
        |> be_equal("POSThttp://localhost:9876/searchmilk")
        |> or_fail_with("The body is added to the key")
      }),
    ]),
    group("step 2: a key with the body", [
      it("each body plays back its own answer", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_body")
        record_two_searches(recordings)
        let assert Ok(playback) = start_search_recorder("playback", recordings)

        // Act
        let answers =
          list.map(["milk", "eggs"], fn(words) {
            post_search(words, playback) |> result.map(fn(r) { r.body })
          })

        // Assert
        answers
        |> should
        |> be_equal([
          Ok(<<"{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"milk\"}">>),
          Ok(<<"{\"method\":\"POST\",\"url\":\"/post\",\"data\":\"eggs\"}">>),
        ])
        |> or_fail_with("Each body should find its recording")
      }),
      it("the default key finds two recordings and refuses", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_ambiguous")
        record_two_searches(recordings)
        let assert Ok(playback) =
          recorder.new()
          |> recorder.directory(recordings)
          |> recorder.mode("playback")
          |> recorder.start()

        // Act
        let result =
          post_search("eggs", playback) |> result.map(fn(r) { r.status })

        // Assert
        result
        |> should
        |> be_equal(
          Error(
            RequestError(Unexpected(
              "Ambiguous recording match for key: POSThttp://localhost:"
              <> int.to_string(mock_server.port())
              <> "/post (2 recordings)",
            )),
          ),
        )
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
          |> recorder.mode("record")
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
      it("the caller still gets the live cookie", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_live_cookie")
        use port <- edge_server.with("set_cookie")
        let assert Ok(scrubbing) =
          start_scrubbing_recorder("record", recordings)

        // Act
        let headers =
          session_request(port, "test-token-123")
          |> client.recorder(scrubbing)
          |> client.send()
          |> result.map(fn(response) { response.headers })

        // Assert
        headers
        |> should
        |> be_equal(
          Ok([
            client.Header("set-cookie", "session=abc123"),
            client.Header("content-length", "2"),
          ]),
        )
        |> or_fail_with("Scrubbing changes only what is saved")
      }),
      it("the saved file holds no token and no cookie", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_file")
        use port <- edge_server.with("set_cookie")
        record_session(recordings, port)

        // Act
        let leaks =
          simplifile.read_directory(recordings)
          |> result.try(fn(files) {
            list.try_map(files, fn(file) {
              simplifile.read(recordings <> "/" <> file)
            })
          })
          |> result.map(fn(contents) {
            let all = string.concat(contents)
            #(
              string.contains(all, "test-token-123"),
              string.contains(all, "session=abc123"),
            )
          })

        // Assert
        leaks
        |> should
        |> be_equal(Ok(#(False, False)))
        |> or_fail_with("Neither secret should reach the file")
      }),
      it("playback with another token still matches", fn() {
        // Arrange
        let recordings = temp_directory.path("guide_matching_other_token")
        use port <- edge_server.with("set_cookie")
        record_session(recordings, port)
        let assert Ok(playback) =
          start_scrubbing_recorder("playback", recordings)

        // Act
        let answer =
          session_request(port, "other-token")
          |> client.recorder(playback)
          |> client.send()
          |> result.map(fn(response) { #(response.headers, response.body) })

        // Assert
        answer
        |> should
        |> be_equal(Ok(#([client.Header("content-length", "2")], <<"ok">>)))
        |> or_fail_with("The token is not part of the key")
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
          start_scrubbing_recorder("playback", recordings)

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
  let assert Ok(recording) = start_search_recorder("record", recordings)
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
  let assert Ok(scrubbing) = start_scrubbing_recorder("record", recordings)
  let _response =
    session_request(port, "test-token-123")
    |> client.recorder(scrubbing)
    |> client.send()
  let assert Ok(Nil) = recorder.stop(scrubbing)
  Nil
}
