import dream_http_client/client.{
  LogDebug, LogError, LogInfo, LogNone, LogWarning,
}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import gleam/option.{None, Some}
import gleam/string

pub fn tests() -> TestSuite {
  describe("client transport config", [
    group("defaults", [
      it("get_max_connections returns 50 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_max_connections(config)

        // Assert
        value
        |> should
        |> be_equal(50)
        |> or_fail_with("Default max_connections should be 50")
      }),
      it("get_idle_timeout returns 60_000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_idle_timeout(config)

        // Assert
        value
        |> should
        |> be_equal(60_000)
        |> or_fail_with("Default idle_timeout should be 60_000")
      }),
      it("get_default_connect_timeout returns 15_000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_default_connect_timeout(config)

        // Assert
        value
        |> should
        |> be_equal(15_000)
        |> or_fail_with("Default default_connect_timeout should be 15_000")
      }),
      it("get_domain_lookup_timeout returns 5000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_domain_lookup_timeout(config)

        // Assert
        value
        |> should
        |> be_equal(5000)
        |> or_fail_with("Default domain_lookup_timeout should be 5000")
      }),
      it("get_tls_handshake_timeout returns 10_000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_tls_handshake_timeout(config)

        // Assert
        value
        |> should
        |> be_equal(10_000)
        |> or_fail_with("Default tls_handshake_timeout should be 10_000")
      }),
      it("get_keepalive returns 30_000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_keepalive(config)

        // Assert
        value
        |> should
        |> be_equal(30_000)
        |> or_fail_with("Default keepalive should be 30_000")
      }),
      it("get_keepalive_tolerance returns 3 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_keepalive_tolerance(config)

        // Assert
        value
        |> should
        |> be_equal(3)
        |> or_fail_with("Default keepalive_tolerance should be 3")
      }),
      it("get_max_concurrent_streams returns 100 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_max_concurrent_streams(config)

        // Assert
        value
        |> should
        |> be_equal(100)
        |> or_fail_with("Default max_concurrent_streams should be 100")
      }),
      it("get_initial_connection_window_size returns 65_535 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_initial_connection_window_size(config)

        // Assert
        value
        |> should
        |> be_equal(65_535)
        |> or_fail_with(
          "Default initial_connection_window_size should be 65_535",
        )
      }),
      it("get_initial_stream_window_size returns 65_535 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_initial_stream_window_size(config)

        // Assert
        value
        |> should
        |> be_equal(65_535)
        |> or_fail_with("Default initial_stream_window_size should be 65_535")
      }),
      it("get_closing_timeout returns 15_000 by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_closing_timeout(config)

        // Assert
        value
        |> should
        |> be_equal(15_000)
        |> or_fail_with("Default closing_timeout should be 15_000")
      }),
      it("get_log_level returns LogInfo by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_log_level(config)

        // Assert
        value
        |> should
        |> be_equal(LogInfo)
        |> or_fail_with("Default log_level should be LogInfo")
      }),
      it("get_default_certificate_authority_file returns None by default", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.get_default_certificate_authority_file(config)

        // Assert
        value
        |> should
        |> be_equal(None)
        |> or_fail_with(
          "Default default_certificate_authority_file should be None",
        )
      }),
    ]),
    group("setters", [
      it("max_connections sets the value to 200", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.max_connections(config, 200) |> client.get_max_connections

        // Assert
        value
        |> should
        |> be_equal(200)
        |> or_fail_with("max_connections should store 200")
      }),
      it("idle_timeout sets the value to 120_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.idle_timeout(config, 120_000) |> client.get_idle_timeout

        // Assert
        value
        |> should
        |> be_equal(120_000)
        |> or_fail_with("idle_timeout should store 120_000")
      }),
      it("default_connect_timeout sets the value to 30_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.default_connect_timeout(config, 30_000)
          |> client.get_default_connect_timeout

        // Assert
        value
        |> should
        |> be_equal(30_000)
        |> or_fail_with("default_connect_timeout should store 30_000")
      }),
      it("domain_lookup_timeout sets the value to 10_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.domain_lookup_timeout(config, 10_000)
          |> client.get_domain_lookup_timeout

        // Assert
        value
        |> should
        |> be_equal(10_000)
        |> or_fail_with("domain_lookup_timeout should store 10_000")
      }),
      it("tls_handshake_timeout sets the value to 20_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.tls_handshake_timeout(config, 20_000)
          |> client.get_tls_handshake_timeout

        // Assert
        value
        |> should
        |> be_equal(20_000)
        |> or_fail_with("tls_handshake_timeout should store 20_000")
      }),
      it("keepalive sets the value to 60_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.keepalive(config, 60_000) |> client.get_keepalive

        // Assert
        value
        |> should
        |> be_equal(60_000)
        |> or_fail_with("keepalive should store 60_000")
      }),
      it("keepalive_tolerance sets the value to 5", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.keepalive_tolerance(config, 5)
          |> client.get_keepalive_tolerance

        // Assert
        value
        |> should
        |> be_equal(5)
        |> or_fail_with("keepalive_tolerance should store 5")
      }),
      it("max_concurrent_streams sets the value to 500", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.max_concurrent_streams(config, 500)
          |> client.get_max_concurrent_streams

        // Assert
        value
        |> should
        |> be_equal(500)
        |> or_fail_with("max_concurrent_streams should store 500")
      }),
      it("initial_connection_window_size sets the value to 131_070", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.initial_connection_window_size(config, 131_070)
          |> client.get_initial_connection_window_size

        // Assert
        value
        |> should
        |> be_equal(131_070)
        |> or_fail_with("initial_connection_window_size should store 131_070")
      }),
      it("initial_stream_window_size sets the value to 131_070", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.initial_stream_window_size(config, 131_070)
          |> client.get_initial_stream_window_size

        // Assert
        value
        |> should
        |> be_equal(131_070)
        |> or_fail_with("initial_stream_window_size should store 131_070")
      }),
      it("closing_timeout sets the value to 30_000", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.closing_timeout(config, 30_000) |> client.get_closing_timeout

        // Assert
        value
        |> should
        |> be_equal(30_000)
        |> or_fail_with("closing_timeout should store 30_000")
      }),
      it("log_level sets the value to LogWarning", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.log_level(config, LogWarning) |> client.get_log_level

        // Assert
        value
        |> should
        |> be_equal(LogWarning)
        |> or_fail_with("log_level should store LogWarning")
      }),
      it(
        "default_certificate_authority_file sets the value to Some(/etc/ssl/ca.pem)",
        fn() {
          // Arrange
          let config = client.transport_config()

          // Act
          let value =
            client.default_certificate_authority_file(config, "/etc/ssl/ca.pem")
            |> client.get_default_certificate_authority_file

          // Assert
          value
          |> should
          |> be_equal(Some("/etc/ssl/ca.pem"))
          |> or_fail_with(
            "default_certificate_authority_file should store Some(/etc/ssl/ca.pem)",
          )
        },
      ),
      it("max_connections accepts 1", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.max_connections(config, 1) |> client.get_max_connections

        // Assert
        value
        |> should
        |> be_equal(1)
        |> or_fail_with("max_connections should store 1")
      }),
      it("keepalive_tolerance accepts 0", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.keepalive_tolerance(config, 0)
          |> client.get_keepalive_tolerance

        // Assert
        value
        |> should
        |> be_equal(0)
        |> or_fail_with("keepalive_tolerance should store 0")
      }),
      it("max_concurrent_streams accepts 1", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value =
          client.max_concurrent_streams(config, 1)
          |> client.get_max_concurrent_streams

        // Assert
        value
        |> should
        |> be_equal(1)
        |> or_fail_with("max_concurrent_streams should store 1")
      }),
      it("log_level accepts LogDebug", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.log_level(config, LogDebug) |> client.get_log_level

        // Assert
        value
        |> should
        |> be_equal(LogDebug)
        |> or_fail_with("log_level should store LogDebug")
      }),
      it("log_level accepts LogError", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.log_level(config, LogError) |> client.get_log_level

        // Assert
        value
        |> should
        |> be_equal(LogError)
        |> or_fail_with("log_level should store LogError")
      }),
      it("log_level accepts LogNone", fn() {
        // Arrange
        let config = client.transport_config()

        // Act
        let value = client.log_level(config, LogNone) |> client.get_log_level

        // Assert
        value
        |> should
        |> be_equal(LogNone)
        |> or_fail_with("log_level should store LogNone")
      }),
    ]),
    group("builder chain", [
      it("keeps every value of a full chain", fn() {
        // Arrange
        let config =
          client.transport_config()
          |> client.max_connections(200)
          |> client.idle_timeout(120_000)
          |> client.default_connect_timeout(30_000)
          |> client.domain_lookup_timeout(10_000)
          |> client.tls_handshake_timeout(20_000)
          |> client.keepalive(60_000)
          |> client.keepalive_tolerance(5)
          |> client.max_concurrent_streams(500)
          |> client.initial_connection_window_size(131_070)
          |> client.initial_stream_window_size(131_070)
          |> client.closing_timeout(30_000)
          |> client.log_level(LogWarning)
          |> client.default_certificate_authority_file("/etc/ssl/ca.pem")

        // Act
        let values = [
          string.inspect(client.get_max_connections(config)),
          string.inspect(client.get_idle_timeout(config)),
          string.inspect(client.get_default_connect_timeout(config)),
          string.inspect(client.get_domain_lookup_timeout(config)),
          string.inspect(client.get_tls_handshake_timeout(config)),
          string.inspect(client.get_keepalive(config)),
          string.inspect(client.get_keepalive_tolerance(config)),
          string.inspect(client.get_max_concurrent_streams(config)),
          string.inspect(client.get_initial_connection_window_size(config)),
          string.inspect(client.get_initial_stream_window_size(config)),
          string.inspect(client.get_closing_timeout(config)),
          string.inspect(client.get_log_level(config)),
          string.inspect(client.get_default_certificate_authority_file(config)),
        ]

        // Assert
        values
        |> should
        |> be_equal([
          string.inspect(200),
          string.inspect(120_000),
          string.inspect(30_000),
          string.inspect(10_000),
          string.inspect(20_000),
          string.inspect(60_000),
          string.inspect(5),
          string.inspect(500),
          string.inspect(131_070),
          string.inspect(131_070),
          string.inspect(30_000),
          string.inspect(LogWarning),
          string.inspect(Some("/etc/ssl/ca.pem")),
        ])
        |> or_fail_with("Every value of the chain should be kept")
      }),
    ]),
    group("client.configure_transport", [
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
    ]),
  ])
}
