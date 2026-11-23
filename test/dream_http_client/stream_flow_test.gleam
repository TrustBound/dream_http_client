//// Flow control of streams: the client reads the response from the server
//// only as fast as the caller takes it, and a recording says what the
//// server really sent.

import dream_http_client/client.{HttpFailure, TransportFailure}
import dream_http_client/recorder.{directory, mode, start}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mailbox
import fixtures/recorded
import fixtures/temp_directory
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("stream flow control", [
    group("stream_yielder", [
      it("stops the server while the caller does not read", fn() {
        // Arrange
        use port <- edge_server.with("flood")
        let _first =
          edge_server.request(port)
          |> client.stream_yielder
          |> yielder.take(1)
          |> yielder.to_list

        // Act
        process.sleep(500)
        let sent = edge_server.flood_sent(port)

        // Assert
        sent
        |> should
        |> be_equal(False)
        |> or_fail_with(
          "The server should wait for a caller that does not read",
        )
      }),
      it("reads the whole body when the caller keeps reading", fn() {
        // Arrange
        use port <- edge_server.with("flood")

        // Act
        let size =
          edge_server.request(port)
          |> client.stream_yielder
          |> yielder.fold(0, fn(total, chunk) {
            total
            + { chunk |> result.map(bytes_tree.byte_size) |> result.unwrap(0) }
          })

        // Assert
        size
        |> should
        |> be_equal(67_108_864)
        |> or_fail_with("Every byte of the body should arrive")
      }),
    ]),
    group("request bodies", [
      it("send sends the exact bytes of body_bits", fn() {
        // Arrange
        use port <- edge_server.with("echo_body")

        // Act
        let body =
          edge_server.request(port)
          |> client.method(http.Put)
          |> client.body_bits(<<255, 0, 254, 1>>)
          |> client.send()
          |> result.map(fn(response) { response.body })

        // Assert
        body
        |> should
        |> be_equal(Ok(<<255, 0, 254, 1>>))
        |> or_fail_with("The server should get the exact bytes of the body")
      }),
    ]),
    group("error responses", [
      it("stream_yielder reads the whole body of an error response", fn() {
        // Arrange
        use port <- edge_server.with("error_parts")

        // Act
        let first =
          edge_server.request(port)
          |> client.stream_yielder
          |> yielder.first
          |> result.map(
            result.map_error(_, fn(failure) {
              case failure {
                HttpFailure(response) -> #(response.status, response.body)
                TransportFailure(_error) -> #(0, <<>>)
              }
            }),
          )
          |> result.map(result.replace(_, Nil))

        // Assert
        first
        |> should
        |> be_equal(Ok(Error(#(500, <<"helloworld">>))))
        |> or_fail_with("The error body should arrive whole")
      }),
    ]),
    group("start_stream", [
      it("stops the server while the chunk handler is busy", fn() {
        // Arrange
        use port <- edge_server.with("flood")
        let assert Ok(handle) =
          edge_server.request(port)
          |> client.on_stream_chunk(fn(_data) { process.sleep(2000) })
          |> client.start_stream()

        // Act
        process.sleep(500)
        let sent = edge_server.flood_sent(port)
        client.cancel_stream_handle(handle)

        // Assert
        sent
        |> should
        |> be_equal(False)
        |> or_fail_with("The server should wait for a busy chunk handler")
      }),
      it("reads the whole body when the handler returns at once", fn() {
        // Arrange
        use port <- edge_server.with("flood")
        let sizes = process.new_subject()
        let ended = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.on_stream_chunk(fn(data) {
            process.send(sizes, bit_array.byte_size(data))
          })
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
          |> client.start_stream()

        // Act
        let assert Ok(Nil) = process.receive(ended, 20_000)
        let size = mailbox.drain(sizes) |> int.sum

        // Assert
        size
        |> should
        |> be_equal(67_108_864)
        |> or_fail_with("Every byte of the body should arrive")
      }),
    ]),
    group("recordings", [
      it("stream_yielder saves the status that the server sent", fn() {
        // Arrange
        use port <- edge_server.with("created_stream")
        let path =
          temp_directory.path("flow_yield_status_" <> int.to_string(port))
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _chunks =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.to_list
        let assert Ok(Nil) = recorder.stop(rec)
        let statuses = recorded.saved_statuses(path)

        // Assert
        statuses
        |> should
        |> be_equal(Ok([201]))
        |> or_fail_with("The recording should have the status 201")
      }),
      it("start_stream saves the status that the server sent", fn() {
        // Arrange
        use port <- edge_server.with("created_stream")
        let path =
          temp_directory.path("flow_start_status_" <> int.to_string(port))
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let ended = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
          |> client.start_stream()

        // Act
        let assert Ok(Nil) = process.receive(ended, 5000)
        let assert Ok(Nil) = recorder.stop(rec)
        let statuses = recorded.saved_statuses(path)

        // Assert
        statuses
        |> should
        |> be_equal(Ok([201]))
        |> or_fail_with("The recording should have the status 201")
      }),
      it("stream_yielder saves no recording of a stream that failed", fn() {
        // Arrange
        use port <- edge_server.with("chunk_then_close")
        let path =
          temp_directory.path("flow_yield_failed_" <> int.to_string(port))
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()

        // Act
        let _chunks =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.stream_yielder
          |> yielder.take(2)
          |> yielder.to_list
        let saved = recorder.get_recordings(rec) |> list.length
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        saved
        |> should
        |> be_equal(0)
        |> or_fail_with("A stream that failed should not be saved")
      }),
      it("start_stream saves no recording of a stream that failed", fn() {
        // Arrange
        use port <- edge_server.with("chunk_then_close")
        let path =
          temp_directory.path("flow_start_failed_" <> int.to_string(port))
        let assert Ok(rec) =
          recorder.new() |> directory(path) |> mode("record") |> start()
        let failed = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.recorder(rec)
          |> client.on_stream_error(fn(_failure) { process.send(failed, Nil) })
          |> client.start_stream()

        // Act
        let assert Ok(Nil) = process.receive(failed, 5000)
        let saved = recorder.get_recordings(rec) |> list.length
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        saved
        |> should
        |> be_equal(0)
        |> or_fail_with("A stream that failed should not be saved")
      }),
    ]),
  ])
}
