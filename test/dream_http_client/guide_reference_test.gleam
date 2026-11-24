//// Tests for the settings reference (docs/guides/settings-reference.md).
//// Each test reads the defaults with the getters and asserts the values
//// that the reference tables show.

import dream_http_client/client.{LogWarning}
import dream_http_client/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None}

pub fn tests() -> TestSuite {
  describe("settings reference", [
    it("record mode needs a directory", fn() {
      // Act
      let started =
        recorder.new()
        |> recorder.mode("record")
        |> recorder.start()

      // Assert
      started
      |> should
      |> be_equal(Error("Recorder directory is required for record/playback"))
      |> or_fail_with("A recorder in record mode needs a directory")
    }),
    it("a new request has the defaults of the request table", fn() {
      // Arrange
      let request = client.new()

      // Act
      let defaults = #(
        client.get_method(request),
        client.get_scheme(request),
        client.get_host(request),
        client.get_port(request),
        client.get_path(request),
        client.get_query(request),
        client.get_headers(request),
        client.get_body(request),
      )

      // Assert
      defaults
      |> should
      |> be_equal(
        #(http.Get, http.Https, "localhost", None, "", None, [], <<>>),
      )
      |> or_fail_with("The request table should match client.new()")
    }),
    it("a new request leaves the connection settings unset", fn() {
      // Arrange
      let request = client.new()

      // Act
      let unset = #(
        client.get_timeout(request),
        client.get_connect_timeout(request),
        client.get_auto_redirect(request),
        client.get_protocols(request),
        client.get_certificate_authority_file(request),
        client.get_pool(request),
        option.is_none(client.get_recorder(request)),
      )

      // Assert
      unset
      |> should
      |> be_equal(#(None, None, None, None, None, None, True))
      |> or_fail_with("Unset settings use the defaults of the table")
    }),
    it("transport_config has the defaults of the transport table", fn() {
      // Arrange
      let config = client.transport_config()

      // Act
      let defaults = #(
        client.get_max_connections(config),
        client.get_idle_timeout(config),
        client.get_default_connect_timeout(config),
        client.get_domain_lookup_timeout(config),
        client.get_tls_handshake_timeout(config),
        client.get_keepalive(config),
        client.get_keepalive_tolerance(config),
        client.get_max_concurrent_streams(config),
        client.get_initial_connection_window_size(config),
        client.get_initial_stream_window_size(config),
        client.get_closing_timeout(config),
        client.get_default_certificate_authority_file(config),
        client.get_log_level(config),
      )

      // Assert
      defaults
      |> should
      |> be_equal(#(
        50,
        60_000,
        15_000,
        5000,
        10_000,
        30_000,
        3,
        100,
        65_535,
        65_535,
        15_000,
        None,
        LogWarning,
      ))
      |> or_fail_with("The transport table should match transport_config()")
    }),
  ])
}
