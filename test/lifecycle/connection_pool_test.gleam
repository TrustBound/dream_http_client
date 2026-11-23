//// Tests for the connection pool: which connection a request gets.
////
//// Each test restarts the application, so it starts with no connections
//// and a new supervisor, and then counts the connections in the connection
//// table. A restart of the application, not of the connection manager,
//// keeps the restarts under the restart limit of the supervisor.
//// They change state that every request uses, so the test entry point runs
//// this suite last, one test at a time.

import dream_http_client/client.{
  ConnectFailed, Http2Only, RequestError, TimedOut,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/application.{
  connection_count, restart_application, restart_connection_manager,
}
import fixtures/edge_server
import fixtures/mailbox
import fixtures/mock_server
import fixtures/tls_server
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
    group("HTTP/2 streams", [
      it("shares one HTTP/2 connection between streams", fn() {
        // Arrange
        restart_application()
        let started = process.new_subject()
        let request =
          mock_server.get("/stream/slow")
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
        let assert Ok(first) = client.start_stream(request)
        let assert Ok(Nil) = process.receive(started, 5000)
        let assert Ok(second) = client.start_stream(request)
        let assert Ok(Nil) = process.receive(started, 5000)
        let assert Ok(third) = client.start_stream(request)
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let count = connection_count()
        list.each([first, second, third], client.cancel_stream_handle)

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("Three HTTP/2 streams should share one connection")
      }),
      it(
        "opens a new HTTP/2 connection at the stream limit of the server",
        fn() {
          // Arrange
          restart_application()
          use port <- edge_server.with("h2s_limit_2")
          let started = process.new_subject()
          let request =
            edge_server.request(port)
            |> client.protocols(Http2Only)
            |> client.on_stream_start(fn(_headers) {
              process.send(started, Nil)
            })
          let assert Ok(_first) = client.start_stream(request)
          let assert Ok(Nil) = process.receive(started, 5000)
          let assert Ok(_second) = client.start_stream(request)
          let assert Ok(Nil) = process.receive(started, 5000)
          let assert Ok(_third) = client.start_stream(request)
          let assert Ok(Nil) = process.receive(started, 5000)

          // Act
          let count = connection_count()

          // Assert
          count
          |> should
          |> be_equal(2)
          |> or_fail_with(
            "A limit of 2 streams should put 3 streams on 2 connections",
          )
        },
      ),
      it("follows a stream limit that the server raises", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_limit_raise")
        let started = process.new_subject()
        let request =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
        let assert Ok(_first) = client.start_stream(request)
        let assert Ok(Nil) = process.receive(started, 5000)
        process.sleep(100)
        let assert Ok(_second) = client.start_stream(request)
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with(
          "A raised limit should let a second stream share the connection",
        )
      }),
      it("sends a refused stream again on another connection", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_refuse_first")
        let request = edge_server.request(port) |> client.protocols(Http2Only)

        // Act
        let result =
          client.send(request)
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with("A refused stream should be sent again")
      }),
      it("sends a request again on another connection after a GOAWAY", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_goaway_second")
        let started = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let result =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.send()
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with(
          "A request after a GOAWAY should go to a new connection",
        )
      }),
      it("keeps a running stream after a GOAWAY", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_goaway_second")
        let started = process.new_subject()
        let assert Ok(handle) =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let _ =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.send()
        let active = client.is_stream_active(handle)

        // Assert
        active
        |> should
        |> be_equal(True)
        |> or_fail_with("A GOAWAY should not stop a stream the server kept")
      }),
      it("reports a server that never sends its SETTINGS", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_no_settings")
        let request =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.connect_timeout(200)

        // Act
        let result = client.send(request)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(ConnectFailed("Connection timed out"))))
        |> or_fail_with("A missing SETTINGS frame should fail the connect")
      }),
    ]),
    group("HTTP/2 over TLS", [
      it("shares one connection with a Dream server over TLS", fn() {
        // Arrange
        restart_application()
        use certificates <- tls_server.with(19_980)
        let request =
          tls_server.request(certificates.port)
          |> client.path("/tls/slow")
          |> client.protocols(Http2Only)
          |> client.certificate_authority_file(
            certificates.certificate_authority,
          )
        let results = process.new_subject()
        list.each([1, 2, 3], fn(_attempt) {
          process.spawn(fn() {
            client.send(request)
            |> result.map(fn(response) { response.status })
            |> process.send(results, _)
          })
        })

        // Act
        let statuses = mailbox.take(results, 3, 5000)
        let count = connection_count()

        // Assert
        #(statuses, count)
        |> should
        |> be_equal(#([Ok(200), Ok(200), Ok(200)], 1))
        |> or_fail_with(
          "Three requests at once should share one TLS connection",
        )
      }),
      it("opens a new connection at the stream limit of a TLS server", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_limit_2")
        let started = process.new_subject()
        let streaming =
          request
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
        let assert Ok(_first) = client.start_stream(streaming)
        let assert Ok(Nil) = process.receive(started, 5000)
        let assert Ok(_second) = client.start_stream(streaming)
        let assert Ok(Nil) = process.receive(started, 5000)
        let assert Ok(_third) = client.start_stream(streaming)
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(2)
        |> or_fail_with(
          "A limit of 2 streams should put 3 streams on 2 connections",
        )
      }),
      it("follows a stream limit that a TLS server raises", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_limit_raise")
        let started = process.new_subject()
        let streaming =
          request
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
        let assert Ok(_first) = client.start_stream(streaming)
        let assert Ok(Nil) = process.receive(started, 5000)
        process.sleep(100)
        let assert Ok(_second) = client.start_stream(streaming)
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with(
          "A raised limit should let a second stream share the connection",
        )
      }),
      it("sends a stream that a TLS server refused again", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_refuse_first")

        // Act
        let result =
          request
          |> client.protocols(Http2Only)
          |> client.send()
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with("A refused stream should be sent again")
      }),
      it("sends a request again after a GOAWAY from a TLS server", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_goaway_second")
        let started = process.new_subject()
        let assert Ok(_handle) =
          request
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let result =
          request
          |> client.protocols(Http2Only)
          |> client.send()
          |> result.map(fn(response) { #(response.status, response.body) })

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"ok">>)))
        |> or_fail_with(
          "A request after a GOAWAY should go to a new connection",
        )
      }),
      it("keeps a running stream after a GOAWAY from a TLS server", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_goaway_second")
        let started = process.new_subject()
        let assert Ok(handle) =
          request
          |> client.protocols(Http2Only)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let _ = request |> client.protocols(Http2Only) |> client.send()
        let active = client.is_stream_active(handle)

        // Assert
        active
        |> should
        |> be_equal(True)
        |> or_fail_with("A GOAWAY should not stop a stream the server kept")
      }),
      it("reports a TLS server that never sends its SETTINGS", fn() {
        // Arrange
        restart_application()
        use request <- edge_server.with_tls("h2s_no_settings")

        // Act
        let result =
          request
          |> client.protocols(Http2Only)
          |> client.connect_timeout(1000)
          |> client.send()

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(ConnectFailed("Connection timed out"))))
        |> or_fail_with("A missing SETTINGS frame should fail the connect")
      }),
    ]),
    group("every connection busy", [
      it("waits for a free connection at max_connections", fn() {
        // Arrange
        restart_application()
        client.transport_config()
        |> client.max_connections(1)
        |> client.configure_transport()
        use port <- edge_server.with("chunks")
        let started = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let result =
          edge_server.request(port)
          |> client.timeout(5000)
          |> client.send()
          |> result.map(fn(response) { #(response.status, response.body) })
        client.configure_transport(client.transport_config())

        // Assert
        result
        |> should
        |> be_equal(Ok(#(200, <<"onetwothree">>)))
        |> or_fail_with(
          "A request should wait until the stream frees the connection",
        )
      }),
      it("times out while it waits for a free connection", fn() {
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
        let result =
          mock_server.get("/text") |> client.timeout(200) |> client.send()
        client.cancel_stream_handle(handle)
        client.configure_transport(client.transport_config())

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(200))))
        |> or_fail_with("A wait longer than the timeout should give TimedOut")
      }),
      it("keeps waiting when a connection to another origin frees", fn() {
        // Arrange
        restart_application()
        client.transport_config()
        |> client.max_connections(1)
        |> client.configure_transport()
        use port <- edge_server.with("empty")
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)
        process.spawn(fn() {
          process.sleep(50)
          client.send(edge_server.request(port))
        })

        // Act
        let result =
          mock_server.get("/text") |> client.timeout(300) |> client.send()
        client.cancel_stream_handle(handle)
        client.configure_transport(client.transport_config())

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(300))))
        |> or_fail_with(
          "A free connection to another origin should not end the wait",
        )
      }),
      it("opens no connection beyond max_connections", fn() {
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
    group("streams as long as the flow window", [
      it("closes an HTTP/1.1 connection after a stream of 16 chunks", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("sixteen_parts")
        let ended = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
          |> client.start_stream()

        // Act
        let assert Ok(Nil) = process.receive(ended, 10_000)
        process.sleep(100)
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(0)
        |> or_fail_with(
          "The connection of a long HTTP/1.1 stream should be closed",
        )
      }),
      it("keeps an HTTP/2 connection after a stream of 16 chunks", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("h2s_sixteen_parts")
        let ended = process.new_subject()
        let assert Ok(_handle) =
          edge_server.request(port)
          |> client.protocols(Http2Only)
          |> client.on_stream_end(fn(_headers) { process.send(ended, Nil) })
          |> client.start_stream()

        // Act
        let assert Ok(Nil) = process.receive(ended, 10_000)
        process.sleep(100)
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with(
          "An HTTP/2 connection should stay open after a long stream",
        )
      }),
    ]),
    group("pools of their own", [
      it("gives a pool its own connection", fn() {
        // Arrange
        restart_application()
        let _ = client.send(mock_server.get("/text"))

        // Act
        let _ =
          mock_server.get("/text")
          |> client.pool(client.new_pool(max_connections: 5))
          |> client.send()
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(2)
        |> or_fail_with(
          "A pool of its own should not use the default connection",
        )
      }),
      it("uses one connection for requests of the same pool", fn() {
        // Arrange
        restart_application()
        let request =
          mock_server.get("/text")
          |> client.pool(client.new_pool(max_connections: 5))
        let _ = client.send(request)

        // Act
        let _ = client.send(request)
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(1)
        |> or_fail_with("Requests of one pool should share its connection")
      }),
      it("gives two pools two connections", fn() {
        // Arrange
        restart_application()
        let _ =
          mock_server.get("/text")
          |> client.pool(client.new_pool(max_connections: 5))
          |> client.send()

        // Act
        let _ =
          mock_server.get("/text")
          |> client.pool(client.new_pool(max_connections: 5))
          |> client.send()
        let count = connection_count()

        // Assert
        count
        |> should
        |> be_equal(2)
        |> or_fail_with("Two pools should not share a connection")
      }),
      it("holds a pool to its own connection limit", fn() {
        // Arrange
        restart_application()
        let pool = client.new_pool(max_connections: 1)
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.pool(pool)
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let result =
          mock_server.get("/text")
          |> client.pool(pool)
          |> client.timeout(200)
          |> client.send()
        client.cancel_stream_handle(handle)

        // Assert
        result
        |> should
        |> be_equal(Error(RequestError(TimedOut(200))))
        |> or_fail_with("A full pool should make the request wait")
      }),
      it("does not hold the default pool to the limit of another pool", fn() {
        // Arrange
        restart_application()
        let started = process.new_subject()
        let assert Ok(handle) =
          mock_server.get("/stream/slow")
          |> client.pool(client.new_pool(max_connections: 1))
          |> client.on_stream_start(fn(_headers) { process.send(started, Nil) })
          |> client.start_stream()
        let assert Ok(Nil) = process.receive(started, 5000)

        // Act
        let status =
          mock_server.get("/text")
          |> client.timeout(1000)
          |> client.send()
          |> result.map(fn(response) { response.status })
        client.cancel_stream_handle(handle)

        // Assert
        status
        |> should
        |> be_equal(Ok(200))
        |> or_fail_with("The default pool should have room")
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
