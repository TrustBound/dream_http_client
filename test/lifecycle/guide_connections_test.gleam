//// Tests for the snippets of the connections guide
//// (docs/guides/connection-pools.md). Each test restarts the application,
//// so it starts with no connections, then counts the connections that the
//// guide's requests open. They change the global transport configuration
//// and read every log event, so they run with the other lifecycle suites,
//// one test at a time.

import dream_http_client/client.{type SendError, TimedOut}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/application.{connection_count, restart_application}
import fixtures/edge_server
import fixtures/log_capture
import fixtures/mock_server
import gleam/http
import gleam/int
import gleam/list
import gleam/string
import snippets/guide_connections_http2.{feed_request}
import snippets/guide_connections_limit.{limit_connections}
import snippets/guide_connections_parallel.{send_all}
import snippets/guide_connections_pool.{report_request, reports_pool}
import snippets/guide_connections_tuning.{
  busy_service_config, configure_busy_service,
}

pub fn tests() -> TestSuite {
  describe("connections guide", [
    group("step 1: how connections are reused", [
      it("four requests one after another use one connection", fn() {
        // Arrange
        restart_application()

        // Act
        list.each([1, 2, 3, 4], fn(_attempt) {
          let _response = client.send(mock_server.get("/stream/fast"))
          Nil
        })

        // Assert
        connection_count()
        |> should
        |> be_equal(1)
        |> or_fail_with("Requests one after another share a connection")
      }),
      it("four requests at once use four HTTP/1.1 connections", fn() {
        // Arrange
        restart_application()

        // Act
        let statuses = send_all(list.repeat(mock_server.get("/stream/fast"), 4))

        // Assert
        #(statuses, connection_count())
        |> should
        |> be_equal(#([Ok(200), Ok(200), Ok(200), Ok(200)], 4))
        |> or_fail_with("Each running HTTP/1.1 request needs a connection")
      }),
      it("a second round of four requests reuses the four connections", fn() {
        // Arrange
        restart_application()
        let requests = list.repeat(mock_server.get("/stream/fast"), 4)
        let _first_round = send_all(requests)

        // Act
        let _second_round = send_all(requests)

        // Assert
        connection_count()
        |> should
        |> be_equal(4)
        |> or_fail_with("The pool keeps the connections")
      }),
    ]),
    group("step 2: HTTP/2", [
      it("four HTTP/2 requests at once share one connection", fn() {
        // Arrange
        restart_application()
        let api =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("localhost")
          |> client.port(mock_server.port())
        let request = feed_request(api)

        // Act
        let statuses = send_all(list.repeat(request, 4))

        // Assert
        #(statuses, connection_count())
        |> should
        |> be_equal(#([Ok(200), Ok(200), Ok(200), Ok(200)], 1))
        |> or_fail_with("HTTP/2 multiplexes the requests")
      }),
    ]),
    group("step 3: a limit", [
      it("the default limit is 50 connections to a host", fn() {
        // Act
        let limit = client.get_max_connections(client.transport_config())

        // Assert
        limit
        |> should
        |> be_equal(50)
        |> or_fail_with("The default max_connections is 50")
      }),
      it("four requests share two connections at a limit of 2", fn() {
        // Arrange
        restart_application()
        limit_connections(2)

        // Act
        let statuses = send_all(list.repeat(mock_server.get("/stream/fast"), 4))
        let count = connection_count()
        client.configure_transport(client.transport_config())

        // Assert
        #(statuses, count)
        |> should
        |> be_equal(#([Ok(200), Ok(200), Ok(200), Ok(200)], 2))
        |> or_fail_with("Two requests wait for a free connection")
      }),
      it("a request that waits longer than its timeout fails", fn() {
        // Arrange
        restart_application()
        limit_connections(2)
        let request = mock_server.get("/stream/fast") |> client.timeout(500)

        // Act
        let outcomes = send_all(list.repeat(request, 4)) |> describe_all()
        client.configure_transport(client.transport_config())

        // Assert
        outcomes
        |> should
        |> be_equal(["200", "200", "TimedOut(500)", "TimedOut(500)"])
        |> or_fail_with("Two requests should time out while they wait")
      }),
    ]),
    group("step 4: a pool of its own", [
      it("pool requests share one connection, the others do not wait", fn() {
        // Arrange
        restart_application()
        let reports = reports_pool()
        let api =
          client.new()
          |> client.scheme(http.Http)
          |> client.host("localhost")
          |> client.port(mock_server.port())
        let pooled = list.repeat(report_request(api, reports), 3)
        let others = list.repeat(mock_server.get("/stream/fast"), 2)

        // Act
        let statuses = send_all(list.append(pooled, others))

        // Assert
        #(statuses, connection_count())
        |> should
        |> be_equal(#([Ok(200), Ok(200), Ok(200), Ok(200), Ok(200)], 3))
        |> or_fail_with("One connection for the pool, two for the others")
      }),
    ]),
    group("step 5: transport settings", [
      it("busy_service_config holds the three settings", fn() {
        // Act
        let config = busy_service_config()

        // Assert
        #(
          client.get_max_connections(config),
          client.get_idle_timeout(config),
          client.get_max_concurrent_streams(config),
        )
        |> should
        |> be_equal(#(200, 120_000, 500))
        |> or_fail_with("The config should hold the three settings")
      }),
      it(
        "configure_busy_service lets four requests open four connections",
        fn() {
          // Arrange
          restart_application()
          limit_connections(2)

          // Act
          configure_busy_service()
          let _statuses =
            send_all(list.repeat(mock_server.get("/stream/fast"), 4))
          let count = connection_count()
          client.configure_transport(client.transport_config())

          // Assert
          count
          |> should
          |> be_equal(4)
          |> or_fail_with("The new limit of 200 replaces the limit of 2")
        },
      ),
      it("configure_transport sets every setting, not only the new one", fn() {
        // Arrange
        restart_application()
        limit_connections(2)

        // Act
        client.transport_config()
        |> client.idle_timeout(30_000)
        |> client.configure_transport()
        let _statuses =
          send_all(list.repeat(mock_server.get("/stream/fast"), 4))
        let count = connection_count()
        client.configure_transport(client.transport_config())

        // Assert
        count
        |> should
        |> be_equal(4)
        |> or_fail_with("max_connections goes back to its default of 50")
      }),
    ]),
    group("step 6: the log", [
      it("a closed connection logs a warning for each connection", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("close")

        // Act
        let #(_result, lines) =
          log_capture.capture(
            fn() { client.send(edge_server.request(port)) },
            1000,
          )

        // Assert
        lines
        |> should
        |> be_equal([
          "warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1",
          "warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1",
        ])
        |> or_fail_with("Each of the two connections logs a warning")
      }),
      it("a body the client cannot decompress logs a warning", fn() {
        // Arrange
        restart_application()

        // Act
        let #(_results, lines) =
          log_capture.capture(
            fn() {
              #(
                client.send(mock_server.get("/unknown-encoding")),
                client.send(mock_server.get("/corrupted-gzip")),
              )
            },
            100,
          )

        // Assert
        lines
        |> should
        |> be_equal([
          "warning: unrecognized Content-Encoding, passing through raw bytes: br",
          "warning: decompression failed, passing through raw bytes",
        ])
        |> or_fail_with("Each body logs one warning")
      }),
      it("a connection that the server closed while idle logs nothing", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("close_after_response")

        // Act
        let #(_result, lines) =
          log_capture.capture(
            fn() { client.send(edge_server.request(port)) },
            1000,
          )

        // Assert
        lines
        |> should
        |> be_equal([])
        |> or_fail_with("The info line is below the default log level")
      }),
      it("log_level(LogNone) does not hide the warnings today", fn() {
        // Arrange
        restart_application()
        use port <- edge_server.with("close")
        client.transport_config()
        |> client.log_level(client.LogNone)
        |> client.configure_transport()

        // Act
        let #(_result, lines) =
          log_capture.capture(
            fn() { client.send(edge_server.request(port)) },
            1000,
          )
        client.configure_transport(client.transport_config())

        // Assert
        list.unique(lines)
        |> should
        |> be_equal([
          "warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1",
        ])
        |> or_fail_with(
          "The warnings carry no module, so the level is not used",
        )
      }),
    ]),
  ])
}

/// Each outcome as text, sorted, because the requests that get a
/// connection first are not always the same ones.
fn describe_all(statuses: List(Result(Int, SendError))) -> List(String) {
  statuses
  |> list.map(describe_outcome)
  |> list.sort(string.compare)
}

fn describe_outcome(status: Result(Int, SendError)) -> String {
  case status {
    Ok(code) -> int.to_string(code)
    Error(client.RequestError(TimedOut(timeout_ms))) ->
      "TimedOut(" <> int.to_string(timeout_ms) <> ")"
    Error(error) -> string.inspect(error)
  }
}
