//// Guide: Controlling connections, testing
////
//// Tests that report requests stay inside their pool of one connection,
//// and that ordinary requests to the same host do not wait for them.

import dream_http_client/client.{
  type SendError, RequestError, TimedOut, host, path, port, scheme, timeout,
}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/list
import snippets/guide_connections_parallel.{send_all}
import snippets/guide_connections_pool.{report_request, reports_pool}

pub fn tests() -> TestSuite {
  describe("reports pool", [
    it("holds report requests to one connection", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_998)
      let api = test_api(19_998) |> timeout(500)
      let reports = list.repeat(report_request(api, reports_pool()), 3)
      let ordinary = list.repeat(api |> path("/stream/fast"), 2)

      // Act
      let outcomes = send_all(list.append(reports, ordinary))
      server.stop(mock)

      // Assert
      #(count_timeouts(list.take(outcomes, 3)), list.drop(outcomes, 3))
      |> should
      |> be_equal(#(2, [Ok(200), Ok(200)]))
      |> or_fail_with(
        "Two reports should wait for the pool, the others should not wait",
      )
    }),
  ])
}

fn test_api(mock_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
}

fn count_timeouts(outcomes: List(Result(Int, SendError))) -> Int {
  list.count(outcomes, fn(outcome) {
    outcome == Error(RequestError(TimedOut(500)))
  })
}
