//// The recorder used through the client: send, stream_yielder and
//// start_stream in record, playback and passthrough mode.

import dream_http_client/client
import dream_http_client/recorder.{
  directory, mode, request_transformer, response_transformer, start,
}
import dream_http_client/recording
import dream_http_client/storage
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mailbox
import fixtures/mock_server
import fixtures/recorded
import fixtures/temp_directory
import fixtures/transformers
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("client with a recorder", [
    group("client.send", [
      it("client.recorder sets the recorder of the request", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.get_recorder
          |> option.is_some
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(True)
        |> or_fail_with("The request should hold the recorder")
      }),
      it("returns the recorded response in playback mode", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_playback")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("RECORDED"),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"RECORDED">>)))
        |> or_fail_with("Playback should return the recording, not the server")
      }),
      it("returns a recorded error status as a ResponseError", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_playback_error")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recording.RecordedRequest(
                ..recorded.text_request(),
                path: "/status/404",
              ),
              response: recording.BlockingResponse(
                status: 404,
                headers: [#("x-recorded", "yes")],
                body: <<"MODIFIED_CONTENT">>,
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/status/404")
          |> client.recorder(rec)
          |> client.send
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) -> Ok(response)
              client.RequestError(transport) -> Error(transport)
            }
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Error(
            Ok(
              client.HttpResponse(
                status: 404,
                headers: [client.Header("x-recorded", "yes")],
                body: <<"MODIFIED_CONTENT">>,
              ),
            ),
          ),
        )
        |> or_fail_with(
          "The recorded status, headers and body should come back",
        )
      }),
      it("returns the recorded headers of a success", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_playback_headers")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.BlockingResponse(
                status: 201,
                headers: [#("x-recorded", "yes")],
                body: <<"made">>,
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/text") |> client.recorder(rec) |> client.send
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            client.HttpResponse(
              status: 201,
              headers: [client.Header("x-recorded", "yes")],
              body: <<"made">>,
            ),
          ),
        )
        |> or_fail_with(
          "The recorded status, headers and body should come back",
        )
      }),
      it("returns an error for a recorded streaming response", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_streaming")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.StreamingResponse(
                status: 200,
                headers: [],
                chunks: [
                  recording.Chunk(data: <<"one ">>, delay_ms: 0),
                  recording.Chunk(data: <<"two">>, delay_ms: 5),
                ],
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/text") |> client.recorder(rec) |> client.send
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Error(
            client.RequestError(client.Unexpected(
              "Recording contains streaming response, use stream_yielder() instead",
            )),
          ),
        )
        |> or_fail_with("send should not play back a streaming recording")
      }),
      it("returns an error for an ambiguous recording", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_ambiguous")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("one"),
            ),
            "first",
          )
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("two"),
            ),
            "second",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/text") |> client.recorder(rec) |> client.send
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Error(
            client.RequestError(client.Unexpected(
              "Ambiguous recording match for key: GEThttp://localhost:9876/text (2 recordings)",
            )),
          ),
        )
        |> or_fail_with("An ambiguous match should be an error")
      }),
      it("sends a real request in passthrough mode", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("Passthrough should reach the server")
      }),
      it("sends a real request when playback has no recording", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("rc_send_playback_miss"))
          |> mode("playback")
          |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("A miss should reach the server")
      }),
      it("returns the transport error with a recorder", fn() {
        // Arrange
        let assert Ok(rec) = recorder.new() |> start()

        // Act
        let value =
          mock_server.closed_port("/text")
          |> client.recorder(rec)
          |> client.send
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Error(client.RequestError(client.ConnectFailed("Connection refused"))),
        )
        |> or_fail_with("A refused connection should be ConnectFailed")
      }),
      it("returns the real response in record mode", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("rc_send_record_response"))
          |> mode("record")
          |> start()

        // Act
        let value =
          mock_server.get("/status/418")
          |> client.recorder(rec)
          |> client.send
          |> result.map_error(fn(error) {
            case error {
              client.ResponseError(response) ->
                Ok(#(response.status, response.body))
              client.RequestError(transport) -> Error(transport)
            }
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Error(Ok(#(418, <<"{\"status\":418}">>))))
        |> or_fail_with("Record mode should return the real 418")
      }),
      it("saves the status and body in record mode", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_record_saves")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _sent =
          mock_server.get("/status/418") |> client.recorder(rec) |> client.send
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.BlockingResponse(status, _headers, body) -> #(
                  status,
                  body,
                )
                recording.StreamingResponse(status, _headers, _chunks) -> #(
                  status,
                  <<>>,
                )
              }
            }),
          )

        // Assert
        value
        |> should
        |> be_equal(Ok([#(418, <<"{\"status\":418}">>)]))
        |> or_fail_with("The 418 should be saved")
      }),
      it("saves the response headers in record mode", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_record_headers")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _sent =
          mock_server.get("/status/418") |> client.recorder(rec) |> client.send
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.BlockingResponse(_status, headers, _body) ->
                  list.key_find(headers, "content-type")
                recording.StreamingResponse(_status, headers, _chunks) ->
                  list.key_find(headers, "content-type")
              }
            }),
          )

        // Assert
        value
        |> should
        |> be_equal(Ok([Ok("application/json; charset=utf-8")]))
        |> or_fail_with("The Content-Type header should be saved")
      }),
      it("saves the scrubbed response but returns the real one", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_response_transformer")
        let assert Ok(rec) =
          recorder.new()
          |> directory(path)
          |> mode("record")
          |> response_transformer(transformers.scrub_cookies_and_body)
          |> start()

        // Act
        let sent =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)
        let saved_body =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.BlockingResponse(_status, _headers, body) -> body
                recording.StreamingResponse(_status, _headers, _chunks) -> <<
                  "stream",
                >>
              }
            }),
          )
        let value = #(sent, saved_body)

        // Assert
        value
        |> should
        |> be_equal(#(Ok(#(200, <<"Hello, World!">>)), Ok([<<>>])))
        |> or_fail_with(
          "The caller should get the real body and the file the scrubbed one",
        )
      }),
      it("saves the scrubbed request and still plays it back", fn() {
        // Arrange
        let path = temp_directory.path("rc_send_request_transformer")
        let assert Ok(writer) =
          recorder.new()
          |> directory(path)
          |> mode("record")
          |> request_transformer(transformers.scrub_auth_and_body)
          |> start()
        let assert Ok(_sent) =
          mock_server.get("/text")
          |> client.add_header("Authorization", "Bearer secret")
          |> client.recorder(writer)
          |> client.send
        let assert Ok(Nil) = recorder.stop(writer)
        let assert Ok(rec) =
          recorder.new()
          |> directory(path)
          |> mode("playback")
          |> request_transformer(transformers.scrub_auth_and_body)
          |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.add_header("Authorization", "Bearer other")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"Hello, World!">>)))
        |> or_fail_with("The scrubbed recording should still match")
      }),
      it("plays back the committed fixture", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory("test/fixtures/recordings")
          |> mode("playback")
          |> start()

        // Act
        let value =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(#(200, <<"FIXTURE_RESPONSE_NO_NETWORK">>)))
        |> or_fail_with("The fixture should come back, not the server")
      }),
    ]),
    group("client.stream_yielder", [
      it("plays back recorded chunks", fn() {
        // Arrange
        let path = temp_directory.path("rc_yield_playback")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.StreamingResponse(
                status: 200,
                headers: [],
                chunks: [
                  recording.Chunk(data: <<"one ">>, delay_ms: 0),
                  recording.Chunk(data: <<"two">>, delay_ms: 5),
                ],
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let request = mock_server.get("/text") |> client.recorder(rec)
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"one two">>))
        |> or_fail_with("The recorded chunks should come back")
      }),
      it("plays back a blocking recording as one chunk", fn() {
        // Arrange
        let path = temp_directory.path("rc_yield_blocking")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("RECORDED"),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let request = mock_server.get("/text") |> client.recorder(rec)
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> list.map(result.map(_, bytes_tree.to_bit_array))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal([Ok(<<"RECORDED">>)])
        |> or_fail_with("A blocking recording should be one chunk")
      }),
      it("streams from the server when playback has no recording", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("rc_yield_miss"))
          |> mode("playback")
          |> start()

        // Act
        let request = mock_server.get("/stream/fast") |> client.recorder(rec)
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("A miss should stream from the server")
      }),
      it("records a real stream", fn() {
        // Arrange
        let path = temp_directory.path("rc_yield_records")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _chunks =
          mock_server.get("/stream/fast")
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.to_list
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.StreamingResponse(status, _headers, chunks) -> #(
                  status,
                  list.map(chunks, fn(chunk) { chunk.data }) |> bit_array.concat,
                )
                recording.BlockingResponse(status, _headers, _body) -> #(
                  status,
                  <<>>,
                )
              }
            }),
          )

        // Assert
        value
        |> should
        |> be_equal(
          Ok([
            #(200, <<
              "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
              "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
            >>),
          ]),
        )
        |> or_fail_with("The whole stream should be saved")
      }),
      it("plays back what it recorded", fn() {
        // Arrange
        let path = temp_directory.path("rc_yield_round_trip")
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let _chunks =
          mock_server.get("/stream/fast")
          |> client.recorder(writer)
          |> client.stream_yielder
          |> yielder.to_list
        let assert Ok(Nil) = recorder.stop(writer)
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let request = mock_server.get("/stream/fast") |> client.recorder(rec)
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("Playback should give the recorded stream")
      }),
    ]),
    group("client.start_stream", [
      it("plays back recorded chunks to the callbacks", fn() {
        // Arrange
        let path = temp_directory.path("rc_start_playback")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recording.StreamingResponse(
                status: 200,
                headers: [],
                chunks: [
                  recording.Chunk(data: <<"one ">>, delay_ms: 0),
                  recording.Chunk(data: <<"two">>, delay_ms: 5),
                ],
              ),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let end = process.receive(ended, 10_000)
        let value = #(end, mailbox.drain_bits(chunks))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(#(Ok(True), <<"one two">>))
        |> or_fail_with("The callbacks should get the recorded chunks")
      }),
      it("plays back a blocking recording as one chunk", fn() {
        // Arrange
        let path = temp_directory.path("rc_start_blocking")
        let assert Ok(Nil) =
          storage.save_recording_immediately(
            path,
            recording.Recording(
              request: recorded.text_request(),
              response: recorded.ok_response("RECORDED"),
            ),
            "k",
          )
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/text")
          |> client.recorder(rec)
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let end = process.receive(ended, 10_000)
        let value = #(end, mailbox.drain_bits(chunks))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(#(Ok(True), <<"RECORDED">>))
        |> or_fail_with("The callbacks should get the body as one chunk")
      }),
      it("streams from the server when playback has no recording", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("rc_start_miss"))
          |> mode("playback")
          |> start()
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/fast")
          |> client.recorder(rec)
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let end = process.receive(ended, 10_000)
        let value = #(end, mailbox.drain_bits(chunks))
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          #(Ok(True), <<
            "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
            "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
          >>),
        )
        |> or_fail_with("A miss should stream from the server")
      }),
      it("records a real stream", fn() {
        // Arrange
        let path = temp_directory.path("rc_start_records")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let chunks = process.new_subject()
        let ended = process.new_subject()
        let request =
          mock_server.get("/stream/fast")
          |> client.recorder(rec)
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
          |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ended, False) })

        // Act
        let assert Ok(_handle) = client.start_stream(request)
        let assert Ok(True) = process.receive(ended, 10_000)
        let _chunks = mailbox.drain(chunks)
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(
            list.map(_, fn(entry) {
              case entry.response {
                recording.StreamingResponse(status, _headers, recorded_chunks) -> #(
                  status,
                  list.map(recorded_chunks, fn(chunk) { chunk.data })
                    |> bit_array.concat,
                )
                recording.BlockingResponse(status, _headers, _body) -> #(
                  status,
                  <<>>,
                )
              }
            }),
          )

        // Assert
        value
        |> should
        |> be_equal(
          Ok([
            #(200, <<
              "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\n",
              "Chunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n",
            >>),
          ]),
        )
        |> or_fail_with("The whole stream should be saved")
      }),
    ]),
    group("query strings", [
      it("send passes the query string", fn() {
        // Arrange
        let request = mock_server.get("/get") |> client.query("page=1&limit=10")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(200, <<
              "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"page=1&limit=10\",\"headers\":[]}",
            >>),
          ),
        )
        |> or_fail_with("The server should get the query")
      }),
      it("send with no query sends an empty query", fn() {
        // Arrange
        let request = mock_server.get("/get")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(200, <<
              "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"\",\"headers\":[]}",
            >>),
          ),
        )
        |> or_fail_with("The server should get no query")
      }),
      it("send passes encoded characters as they are", fn() {
        // Arrange
        let request =
          mock_server.get("/get")
          |> client.query("name=hello%20world&tag=a%26b&eq=1%3D1")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(200, <<
              "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"name=hello%20world&tag=a%26b&eq=1%3D1\",\"headers\":[]}",
            >>),
          ),
        )
        |> or_fail_with("The query should not be encoded twice")
      }),
      it("send with an empty query sends an empty query", fn() {
        // Arrange
        let request = mock_server.get("/get") |> client.query("")

        // Act
        let value =
          client.send(request) |> result.map(fn(r) { #(r.status, r.body) })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(200, <<
              "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"\",\"headers\":[]}",
            >>),
          ),
        )
        |> or_fail_with("An empty query should arrive empty")
      }),
      it("stream_yielder passes the query string", fn() {
        // Arrange
        let request = mock_server.get("/get") |> client.query("format=json")

        // Act
        let value =
          client.stream_yielder(request)
          |> yielder.to_list
          |> result.all
          |> result.map(fn(chunks) {
            bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
          })

        // Assert
        value
        |> should
        |> be_equal(
          Ok(<<
            "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"format=json\",\"headers\":[]}",
          >>),
        )
        |> or_fail_with("The stream request should carry the query")
      }),
      it("start_stream passes the query string", fn() {
        // Arrange
        let chunks = process.new_subject()
        let request =
          mock_server.get("/get")
          |> client.query("stream_key=abc")
          |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })

        // Act
        let assert Ok(handle) = client.start_stream(request)
        client.await_stream(handle)
        let value = mailbox.drain_bits(chunks)

        // Assert
        value
        |> should
        |> be_equal(<<
          "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"stream_key=abc\",\"headers\":[]}",
        >>)
        |> or_fail_with("The stream request should carry the query")
      }),
      it("record mode saves the query", fn() {
        // Arrange
        let path = temp_directory.path("rc_query_record")
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _sent =
          mock_server.get("/get")
          |> client.query("search=hello")
          |> client.recorder(rec)
          |> client.send
        let assert Ok(Nil) = recorder.stop(rec)
        let value =
          storage.load_recordings(path)
          |> result.map(list.map(_, fn(entry) { entry.request.query }))

        // Assert
        value
        |> should
        |> be_equal(Ok([Some("search=hello")]))
        |> or_fail_with("The saved request should hold the query")
      }),
      it("playback matches on the query", fn() {
        // Arrange
        let path = temp_directory.path("rc_query_playback")
        let assert Ok(writer) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let assert Ok(_sent) =
          mock_server.get("/get")
          |> client.query("id=42")
          |> client.recorder(writer)
          |> client.send
        let assert Ok(Nil) = recorder.stop(writer)
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("playback") |> start()

        // Act
        let value =
          mock_server.get("/get")
          |> client.query("id=42")
          |> client.recorder(rec)
          |> client.send
          |> result.map(fn(r) { #(r.status, r.body) })
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        value
        |> should
        |> be_equal(
          Ok(
            #(200, <<
              "{\"method\":\"GET\",\"url\":\"/get\",\"query\":\"id=42\",\"headers\":[]}",
            >>),
          ),
        )
        |> or_fail_with("Playback should match the query")
      }),
    ]),
  ])
}
