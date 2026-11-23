//// Tests for the connection pool: which connection a request gets.
////
//// Each test restarts the application, so it starts with no connections
//// and a new supervisor, and then counts the connections in the connection
//// table. A restart of the application, not of the connection manager,
//// keeps the restarts under the restart limit of the supervisor.
//// They change state that every request uses, so the test entry point runs
//// this suite last, one test at a time.

import dream_http_client/client.{Http2Only}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/application.{
  connection_count, restart_application, restart_connection_manager,
}
import fixtures/mock_server
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite(Nil) {
  describe("connection pool", [
    group("free connections", [
      it("uses one connection for requests sent one after another", fn() {
        // Arrange
        restart_application()

        // Act
        list.each([1, 2, 3, 4, 5], fn(_attempt) {
          let _ = client.send(mock_server.get("/text"))
          Nil
        })
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("Requests one after another should share a connection")
      }),
      it("uses the connection of a stream that ended", fn() {
        // Arrange
        restart_application()
        let _ =
          client.stream_yielder(mock_server.get("/stream/fast"))
          |> yielder.to_list()

        // Act
        let _ = client.send(mock_server.get("/text"))
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with(
          "A request should use the connection of an ended stream",
        )
      }),
    ]),
    group("busy connections", [
      it("never sends a request behind a running stream", fn() {
        // Arrange
        restart_application()
        client.transport_config()
        |> client.max_connections(2)
        |> client.configure_transport()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let statuses =
          list.map([1, 2, 3, 4, 5, 6], fn(_attempt) {
            mock_server.get("/text")
            |> client.timeout(1000)
            |> client.send()
            |> result.map(fn(response) { response.status })
          })
        client.cancel_stream_handle(handle)
        client.configure_transport(client.transport_config())

        // Assert
        statuses
        |> should
        |> be_equal([Ok(200), Ok(200), Ok(200), Ok(200), Ok(200), Ok(200)])
        |> or_fail_with("No request should wait behind the slow stream")
      }),
      it("keeps a connection that serves a stream past the idle timeout", fn() {
        // Arrange
        restart_application()
        client.transport_config()
        |> client.idle_timeout(50)
        |> client.configure_transport()
        restart_connection_manager()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        process.sleep(300)
        let count = connection_count()
        client.cancel_stream_handle(handle)
        client.configure_transport(client.transport_config())
        restart_connection_manager()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("The idle check should not close a busy connection")
      }),
    ]),
    group("every connection busy", [
      it("shares the busy connection at max_connections", fn() {
        // Arrange
        restart_application()
        client.transport_config()
        |> client.max_connections(1)
        |> client.configure_transport()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let _ = mock_server.get("/text") |> client.timeout(200) |> client.send()
        let count = connection_count()
        client.cancel_stream_handle(handle)
        client.configure_transport(client.transport_config())

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("At max_connections the pool should open no connection")
      }),
    ]),
    group("canceled streams", [
      it("closes an HTTP/1.1 connection whose stream was canceled", fn() {
        // Arrange
        restart_application()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        client.cancel_stream_handle(handle)
        process.sleep(100)
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(0)
        |> or_fail_with(
          "A canceled HTTP/1.1 stream should close its connection",
        )
      }),
      it("uses an HTTP/2 connection again after its stream was canceled", fn() {
        // Arrange
        restart_application()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)
        client.cancel_stream_handle(handle)
        process.sleep(100)

        // Act
        let _ =
          mock_server.get("/text")
          |> client.protocols(Http2Only)
          |> client.send()
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("A canceled HTTP/2 stream should free its connection")
      }),
    ]),
  ])
}
