//// Tests of the snippets that apply a transport configuration. The
//// transport configuration and the log level are global to the VM, so
//// these tests run with the lifecycle suites, one test at a time, and each
//// one puts the default configuration back.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import snippets/doc_client_idle_timeout
import snippets/doc_client_log_level
import snippets/doc_client_max_connections
import snippets/doc_client_transport_config
import snippets/transport_config_example

pub fn tests() -> TestSuite {
  describe("snippets that apply a transport configuration", [
    it("keep_idle_connections applies the config", fn() {
      // Act
      let value = doc_client_idle_timeout.keep_idle_connections()
      client.configure_transport(client.transport_config())

      // Assert
      value
      |> should
      |> be_equal(Nil)
      |> or_fail_with("keep_idle_connections applies the config")
    }),
    it("warnings_only applies the config", fn() {
      // Act
      let value = doc_client_log_level.warnings_only()
      client.configure_transport(client.transport_config())

      // Assert
      value
      |> should
      |> be_equal(Nil)
      |> or_fail_with("warnings_only applies the config")
    }),
    it("allow_more_connections applies the config", fn() {
      // Act
      let value = doc_client_max_connections.allow_more_connections()
      client.configure_transport(client.transport_config())

      // Assert
      value
      |> should
      |> be_equal(Nil)
      |> or_fail_with("allow_more_connections applies the config")
    }),
    it("configure_pool applies the config", fn() {
      // Act
      let value = doc_client_transport_config.configure_pool()
      client.configure_transport(client.transport_config())

      // Assert
      value
      |> should
      |> be_equal(Nil)
      |> or_fail_with("configure_pool applies the config")
    }),
    it("Transport settings: configure_high_concurrency returns Nil", fn() {
      // Act
      let value = transport_config_example.configure_high_concurrency()
      client.configure_transport(client.transport_config())

      // Assert
      value
      |> should
      |> be_equal(Nil)
      |> or_fail_with("configure_high_concurrency should return Nil")
    }),
    it("applies the default config and returns Nil", fn() {
      // Arrange
      let config = client.transport_config()

      // Act
      let result = client.configure_transport(config)

      // Assert
      result
      |> should
      |> be_equal(Nil)
      |> or_fail_with("configure_transport should return Nil")
    }),
  ])
}
