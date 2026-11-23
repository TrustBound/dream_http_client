//// A new `idle_timeout` applies at once: the idle check that was scheduled
//// with the old value (60 seconds by default) does not delay it. These
//// tests change the global transport configuration, so they run with the
//// other lifecycle suites, one test at a time.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{connection_count, restart_application}
import fixtures/mock_server
import gleam/erlang/process

pub fn tests() -> TestSuite {
  describe("idle_timeout", [
    it("with the default of 60 seconds, an idle connection stays open", fn() {
      // Arrange
      restart_application()

      // Act
      let count = open_count_after_one_second()

      // Assert
      count
      |> should
      |> be_equal(1)
      |> or_fail_with("The server does not close the idle connection")
    }),
    it("a new idle_timeout of 200 ms closes an idle connection at once", fn() {
      // Arrange
      restart_application()
      client.transport_config()
      |> client.idle_timeout(200)
      |> client.configure_transport()

      // Act
      let count = open_count_after_one_second()
      client.configure_transport(client.transport_config())

      // Assert
      count
      |> should
      |> be_equal(0)
      |> or_fail_with("The new value applies, not the 60 seconds")
    }),
  ])
}

/// Sends one request, waits one second, and returns the number of open
/// connections.
fn open_count_after_one_second() -> Int {
  let _response = client.send(mock_server.get("/text"))
  process.sleep(1000)
  connection_count()
}
