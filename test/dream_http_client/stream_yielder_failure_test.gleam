//// Tests for a stream_yielder that fails: it yields one Error, then ends.
////
//// Each test reads at most five items, so a yielder that does not end
//// gives a list that is too long, and the test does not hang.

import dream_http_client/client
import dream_http_client/recorder.{directory, mode, start}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/edge_server
import fixtures/mock_server
import fixtures/stream_process
import fixtures/temp_directory
import gleam/bytes_tree.{type BytesTree}
import gleam/list
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("client.stream_yielder after an error", [
    group("without a recorder", [
      it("ends after the error of a stream that drops", fn() {
        // Arrange
        let request = mock_server.get("/stream/drop")

        // Act
        let items = read_at_most_five(request)

        // Assert
        items
        |> should
        |> be_equal([
          Ok(<<"Drop chunk 1\n">>),
          Ok(<<"Drop chunk 2\n">>),
          Error("Remote closed connection"),
        ])
        |> or_fail_with("A dropped stream should yield one error, then end")
      }),
      it("ends after the error of a stream that times out", fn() {
        // Arrange
        let request = mock_server.get("/stream/slow") |> client.timeout(300)

        // Act
        let items = read_at_most_five(request)

        // Assert
        items
        |> should
        |> be_equal([Error("Timed out after 300ms")])
        |> or_fail_with("A stream that timed out should yield one error")
      }),
      it("ends after the error of a 500 response", fn() {
        // Arrange
        let request = mock_server.get("/stream/error")

        // Act
        let items = read_at_most_five(request)

        // Assert
        items
        |> should
        |> be_equal([
          Error(
            "HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
          ),
        ])
        |> or_fail_with("A 500 response should yield one error, then end")
      }),
      it("ends after the error of a refused connection", fn() {
        // Arrange
        let request = mock_server.closed_port("/")

        // Act
        let items = read_at_most_five(request)

        // Assert
        items
        |> should
        |> be_equal([Error("Connection failed: Connection refused")])
        |> or_fail_with("A refused connection should yield one error")
      }),
      it("sends the request of a 500 response one time", fn() {
        // Arrange
        use port <- edge_server.with("server_error")
        let request = edge_server.request(port)

        // Act
        let _items = read_at_most_five(request)
        let requests = edge_server.requests_received(port)

        // Assert
        requests
        |> should
        |> be_equal(1)
        |> or_fail_with("The yielder should not send the request again")
      }),
      it("ends after ProcessDown when the stream owner is dead", fn() {
        // Arrange
        let assert yielder.Next(_first_chunk, rest) =
          client.stream_yielder(mock_server.get("/stream/fast"))
          |> yielder.step

        // Act
        let killed = stream_process.kill_yielder_owner()
        let items =
          rest
          |> yielder.take(5)
          |> yielder.to_list
          |> list.map(describe_item)

        // Assert
        #(killed, items)
        |> should
        |> be_equal(#(1, [Error("Process down: noproc")]))
        |> or_fail_with("A dead owner should give one ProcessDown, then end")
      }),
      it("lets to_list return on a stream that drops", fn() {
        // Arrange
        let request = mock_server.get("/stream/drop")

        // Act
        let count =
          client.stream_yielder(request)
          |> yielder.take(5)
          |> yielder.to_list
          |> list.length

        // Assert
        count
        |> should
        |> be_equal(3)
        |> or_fail_with("Two chunks and one error should come")
      }),
    ]),
    group("with a recorder in record mode", [
      it("ends after the error of a stream that drops", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("yielder_failure_record_drop"))
          |> mode(recorder.Record)
          |> start()
        let request = mock_server.get("/stream/drop") |> client.recorder(rec)

        // Act
        let items = read_at_most_five(request)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([
          Ok(<<"Drop chunk 1\n">>),
          Ok(<<"Drop chunk 2\n">>),
          Error("Remote closed connection"),
        ])
        |> or_fail_with("A dropped stream should yield one error, then end")
      }),
      it("ends after the error of a stream that times out", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("yielder_failure_record_timeout"))
          |> mode(recorder.Record)
          |> start()
        let request =
          mock_server.get("/stream/slow")
          |> client.timeout(300)
          |> client.recorder(rec)

        // Act
        let items = read_at_most_five(request)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([Error("Timed out after 300ms")])
        |> or_fail_with("A stream that timed out should yield one error")
      }),
      it("ends after the error of a 500 response", fn() {
        // Arrange
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("yielder_failure_record_500"))
          |> mode(recorder.Record)
          |> start()
        let request = mock_server.get("/stream/error") |> client.recorder(rec)

        // Act
        let items = read_at_most_five(request)
        let assert Ok(Nil) = recorder.stop(rec)

        // Assert
        items
        |> should
        |> be_equal([
          Error(
            "HTTP 500: Error test chunk 1\nError test chunk 2\nError test chunk 3\n",
          ),
        ])
        |> or_fail_with("A 500 response should yield one error, then end")
      }),
      it("sends the request of a 500 response one time", fn() {
        // Arrange
        use port <- edge_server.with("server_error")
        let assert Ok(rec) =
          recorder.new()
          |> directory(temp_directory.path("yielder_failure_record_count"))
          |> mode(recorder.Record)
          |> start()
        let request = edge_server.request(port) |> client.recorder(rec)

        // Act
        let _items = read_at_most_five(request)
        let assert Ok(Nil) = recorder.stop(rec)
        let requests = edge_server.requests_received(port)

        // Assert
        requests
        |> should
        |> be_equal(1)
        |> or_fail_with("The yielder should not send the request again")
      }),
    ]),
  ])
}

// Reads at most five items of the yielder of `request`. A chunk becomes its
// bytes, and an error becomes its text.
fn read_at_most_five(
  request: client.ClientRequest,
) -> List(Result(BitArray, String)) {
  client.stream_yielder(request)
  |> yielder.take(5)
  |> yielder.to_list
  |> list.map(describe_item)
}

fn describe_item(
  item: Result(BytesTree, client.StreamFailure),
) -> Result(BitArray, String) {
  case item {
    Ok(chunk) -> Ok(bytes_tree.to_bit_array(chunk))
    Error(failure) -> Error(client.stream_failure_to_string(failure))
  }
}
