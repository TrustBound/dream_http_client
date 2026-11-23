//// Tests that stop and start the application and its connection manager.
////
//// The application starts before coverage starts, so these tests start it
//// again while coverage runs. They change state that every request uses,
//// so the test entry point runs this suite last, one test at a time.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{
  client_log_level, connection_count, restart_application,
  restart_connection_manager, send_unknown_messages,
}
import fixtures/mock_server
import gleam/erlang/process
import gleam/result

pub fn tests() -> TestSuite {
  describe("application lifecycle", [
    it("serves requests after a restart, with no transport config", fn() {
      // Arrange
      restart_application()

      // Act
      let status =
        client.send(mock_server.get("/text")) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("A restarted application should serve requests")
    }),
    it("sets the debug log level", fn() {
      // Arrange
      let config =
        client.transport_config() |> client.log_level(client.LogDebug)

      // Act
      client.configure_transport(config)
      let level = client_log_level()

      // Assert
      level
      |> should
      |> be_equal("debug")
      |> or_fail_with("LogDebug should set the debug level")
    }),
    it("sets the error log level", fn() {
      // Arrange
      let config =
        client.transport_config() |> client.log_level(client.LogError)

      // Act
      client.configure_transport(config)
      let level = client_log_level()

      // Assert
      level
      |> should
      |> be_equal("error")
      |> or_fail_with("LogError should set the error level")
    }),
    it("turns logging off", fn() {
      // Arrange
      let config = client.transport_config() |> client.log_level(client.LogNone)

      // Act
      client.configure_transport(config)
      let level = client_log_level()

      // Assert
      level
      |> should
      |> be_equal("none")
      |> or_fail_with("LogNone should turn logging off")
    }),
    it("serves requests after an unknown cast and message", fn() {
      // Arrange
      client.configure_transport(client.transport_config())
      send_unknown_messages()

      // Act
      let status =
        client.send(mock_server.get("/text")) |> result.map(fn(r) { r.status })

      // Assert
      status
      |> should
      |> be_equal(Ok(200))
      |> or_fail_with("Unknown messages should not stop the manager")
    }),
    it("closes connections that stay idle", fn() {
      // Arrange
      client.transport_config()
      |> client.idle_timeout(50)
      |> client.configure_transport()
      restart_connection_manager()

      // Act
      let _ = client.send(mock_server.get("/text"))
      process.sleep(300)
      let count = connection_count()
      client.configure_transport(client.transport_config())
      restart_connection_manager()

      // Assert
      count
      |> should
      |> be_equal(0)
      |> or_fail_with("An idle connection should be closed")
    }),
  ])
}
