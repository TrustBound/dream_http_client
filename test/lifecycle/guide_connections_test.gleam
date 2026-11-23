//// Tests for the snippets of the connections guide
//// (docs/guides/connection-pools.md). Each test restarts the application,
//// so it starts with no connections, then counts the connections that the
//// guide's requests open. They change the global transport configuration
//// and read every log event, so they run with the other lifecycle suites,
//// one test at a time. The output that the guide shows in a `text` block
//// is a file in `test/outputs/`, and the tests compare it with the real
//// output.

import dream_http_client/client.{type SendError}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/application.{connection_count, restart_application}
import fixtures/edge_server
import fixtures/log_capture
import fixtures/mock_server
import fixtures/output_file
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
      it("the connections after each round of requests", fn() {
        // Arrange
        let requests = list.repeat(mock_server.get("/stream/fast"), 4)

        // Act
        restart_application()
        list.each(requests, fn(request) {
          let _response = client.send(request)
          Nil
        })
        let one_after_another = connection_count()
        restart_application()
        let at_once = send_all(requests)
        let at_once_count = connection_count()
        let _again = send_all(requests)
        let again_count = connection_count()
        let lines = [
          "send() four times, one after another, to /stream/fast   -> "
            <> connections(one_after_another),
          "send_all of four requests to /stream/fast                -> "
            <> string.inspect(at_once)
            <> ", "
            <> connections(at_once_count),
          "send_all of the same four requests again                 -> "
            <> connections(again_count),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_connections_step_1"))
        |> or_fail_with("Each running HTTP/1.1 request needs a connection")
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
        let lines = [
          string.inspect(statuses) <> ", " <> connections(connection_count()),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_connections_step_2"))
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
      it("four requests at a limit of two, with and without a timeout", fn() {
        // Arrange
        let request = mock_server.get("/stream/fast")
        restart_application()
        limit_connections(2)

        // Act
        let statuses = send_all(list.repeat(request, 4))
        let count = connection_count()
        let outcomes =
          send_all(list.repeat(request |> client.timeout(500), 4))
          |> describe_all()
        client.configure_transport(client.transport_config())
        let lines = [
          "send_all of four requests            -> "
            <> string.inspect(statuses)
            <> ", "
            <> connections(count),
          "the same with timeout(500) on each   -> " <> counted(outcomes),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_connections_step_3"))
        |> or_fail_with("Two requests wait, and time out after 500 ms")
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
        let lines = [
          string.inspect(statuses) <> ", " <> connections(connection_count()),
        ]

        // Assert
        output_file.lines(lines)
        |> should
        |> be_equal(output_file.read("guide_connections_step_4"))
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
            2,
            log_wait_ms,
          )

        // Assert
        lines
        |> should
        |> be_equal([connection_down_line, connection_down_line])
        |> or_fail_with("Each of the two connections logs a warning")
      }),
      it("the default level shows the lines that the guide shows", fn() {
        // Arrange
        restart_application()

        // Act
        let #(_results, lines) =
          log_capture.capture(
            fn() {
              #(
                send_to_edge_server("close_after_response"),
                send_to_edge_server("close"),
                client.send(mock_server.get("/unknown-encoding")),
                client.send(mock_server.get("/corrupted-gzip")),
              )
            },
            5,
            log_wait_ms,
          )

        // Assert
        output_file.lines(list.sort(list.unique(lines), string.compare))
        |> should
        |> be_equal(output_file.read("guide_connections_step_6"))
        |> or_fail_with("The info line and the three warnings")
      }),
      it("LogInfo, the default, shows the info line and the warning", fn() {
        // Arrange
        let level = client.LogInfo

        // Act
        let lines = log_lines_at(level, 3)

        // Assert
        lines
        |> should
        |> be_equal([connection_closed_line, connection_down_line])
        |> or_fail_with("LogInfo shows info lines and warnings")
      }),
      it("LogDebug shows the info line and the warning", fn() {
        // Arrange
        let level = client.LogDebug

        // Act
        let lines = log_lines_at(level, 3)

        // Assert
        lines
        |> should
        |> be_equal([connection_closed_line, connection_down_line])
        |> or_fail_with("LogDebug shows every line")
      }),
      it("LogWarning shows the warning only", fn() {
        // Arrange
        let level = client.LogWarning

        // Act
        let lines = log_lines_at(level, 2)

        // Assert
        lines
        |> should
        |> be_equal([connection_down_line])
        |> or_fail_with("LogWarning hides the info line")
      }),
      it("LogError shows nothing, because the client logs no errors", fn() {
        // Arrange
        let level = client.LogError

        // Act
        let lines = log_lines_at(level, 0)

        // Assert
        lines
        |> should
        |> be_equal([])
        |> or_fail_with("LogError hides the info line and the warning")
      }),
      it("LogNone shows nothing", fn() {
        // Arrange
        let level = client.LogNone

        // Act
        let lines = log_lines_at(level, 0)

        // Assert
        lines
        |> should
        |> be_equal([])
        |> or_fail_with("LogNone hides every line")
      }),
    ]),
  ])
}

/// How long a test waits for the log lines that it expects.
const log_wait_ms = 5000

/// How long a test that expects no log line waits for one that should not
/// come.
const quiet_wait_ms = 1000

fn wait_for(count: Int) -> Int {
  case count {
    0 -> quiet_wait_ms
    _ -> log_wait_ms
  }
}

const connection_closed_line =
  "info: [dream_http] connection closed: pid=<pid> protocol=http reason=closed"

const connection_down_line =
  "warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1"

/// The log lines of the client at `level`, each line once and sorted, for
/// a GET to a server that closes the connection while it is idle (the info
/// line) and a GET to a server that closes it without an answer (the
/// warning). It waits for `count` lines: the info line and one warning for
/// each of the two connections that the second GET uses, or fewer when the
/// level hides some. The transport configuration goes back to the defaults.
fn log_lines_at(level: client.LogLevel, count: Int) -> List(String) {
  restart_application()
  client.transport_config()
  |> client.log_level(level)
  |> client.configure_transport()
  let #(_results, lines) =
    log_capture.capture(
      fn() {
        #(
          send_to_edge_server("close_after_response"),
          send_to_edge_server("close"),
        )
      },
      count,
      wait_for(count),
    )
  client.configure_transport(client.transport_config())
  lines
  |> list.unique()
  |> list.sort(string.compare)
}

/// A GET to a new edge server that plays `scenario`.
fn send_to_edge_server(
  scenario: String,
) -> Result(client.HttpResponse, SendError) {
  edge_server.with(scenario, fn(port) { client.send(edge_server.request(port)) })
}

fn connections(count: Int) -> String {
  case count {
    1 -> "1 connection"
    _ -> int.to_string(count) <> " connections"
  }
}

/// The outcomes as the guide counts them, the successes first, for example
/// `two Ok(200), two Error(RequestError(TimedOut(500)))`.
fn counted(outcomes: List(String)) -> String {
  outcomes
  |> list.unique()
  |> list.sort(fn(first, second) { string.compare(second, first) })
  |> list.map(fn(outcome) {
    let count = list.count(outcomes, fn(other) { other == outcome })
    number_word(count) <> " " <> outcome
  })
  |> string.join(", ")
}

fn number_word(count: Int) -> String {
  case count {
    1 -> "one"
    2 -> "two"
    3 -> "three"
    4 -> "four"
    _ -> int.to_string(count)
  }
}

/// Each outcome as text, sorted, because the requests that get a
/// connection first are not always the same ones.
fn describe_all(statuses: List(Result(Int, SendError))) -> List(String) {
  statuses
  |> list.map(string.inspect)
  |> list.sort(string.compare)
}
