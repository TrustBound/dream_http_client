//// Tests that a stream_yielder that fails gives its connection lease back.
////
//// Each test restarts the application, so the pool starts with no lease,
//// and then reads the leases in the state of the connection manager. Other
//// suites hold leases while they run, so the test entry point runs this
//// suite last, one test at a time.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{lease_count, restart_application}
import fixtures/mock_server
import gleam/list
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("stream_yielder leases after an error", [
    it("holds one lease while a stream runs", fn() {
      // Arrange
      restart_application()

      // Act
      let first =
        client.stream_yielder(mock_server.get("/stream/slow"))
        |> yielder.first
      let count = lease_count()

      // Assert
      #(result_is_ok(first), count)
      |> should
      |> be_equal(#(True, 1))
      |> or_fail_with("A running stream should hold one lease")
    }),
    it("gives the lease back after a stream that drops", fn() {
      // Arrange
      restart_application()

      // Act
      let count = lease_count_after(mock_server.get("/stream/drop"))

      // Assert
      count
      |> should
      |> be_equal(#(3, 0))
      |> or_fail_with("A dropped stream should leave no lease")
    }),
    it("gives the lease back after a stream that times out", fn() {
      // Arrange
      restart_application()
      let request = mock_server.get("/stream/slow") |> client.timeout(300)

      // Act
      let count = lease_count_after(request)

      // Assert
      count
      |> should
      |> be_equal(#(1, 0))
      |> or_fail_with("A stream that timed out should leave no lease")
    }),
    it("gives the lease back after a 500 response", fn() {
      // Arrange
      restart_application()

      // Act
      let count = lease_count_after(mock_server.get("/stream/error"))

      // Assert
      count
      |> should
      |> be_equal(#(1, 0))
      |> or_fail_with("A 500 response should leave no lease")
    }),
    it("holds no lease after a refused connection", fn() {
      // Arrange
      restart_application()

      // Act
      let count = lease_count_after(mock_server.closed_port("/"))

      // Assert
      count
      |> should
      |> be_equal(#(1, 0))
      |> or_fail_with("A refused connection should leave no lease")
    }),
  ])
}

// Reads at most five items of the yielder of `request`, then returns the
// number of items and the number of leases in the pool.
fn lease_count_after(request: client.ClientRequest) -> #(Int, Int) {
  let items =
    client.stream_yielder(request)
    |> yielder.take(5)
    |> yielder.to_list
  #(list.length(items), lease_count())
}

fn result_is_ok(item: Result(Result(a, b), Nil)) -> Bool {
  case item {
    Ok(Ok(_chunk)) -> True
    Ok(Error(_failure)) -> False
    Error(Nil) -> False
  }
}
