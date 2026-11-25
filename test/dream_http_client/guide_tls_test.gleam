//// Tests for the snippets of the TLS guide
//// (docs/guides/tls-and-certificate-authorities.md). Each test starts a
//// TLS server with test certificates on its own port, and asserts the
//// exact value that the guide shows. The output that the guide shows in a
//// `text` block is a file in `test/outputs/`, and the tests compare it with
//// the real output.

import dream_http_client/client.{ConnectFailed, RequestError}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{connection_protocols}
import fixtures/output_file
import fixtures/shown
import fixtures/tls_server
import gleam/list
import gleam/string
import snippets/guide_tls_request.{fetch_greeting, internal_api}

pub fn tests() -> TestSuite {
  describe("TLS guide", [
    it("step 1: the system authorities reject the private certificate", fn() {
      // Arrange
      use certificates <- tls_server.with(19_981)
      let request =
        client.new()
        |> client.host("localhost")
        |> client.port(certificates.port)

      // Act
      let lines = [shown_failure(fetch_greeting(request))]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_tls_unknown_ca"))
      |> or_fail_with("The handshake should fail with unknown_ca")
    }),
    it("step 2: internal_api trusts the private authority", fn() {
      // Arrange
      use certificates <- tls_server.with(19_982)
      let api =
        internal_api(certificates.port, certificates.certificate_authority)

      // Act
      let lines = [
        "fetch_greeting(internal_api(service_port, \"certs/internal-ca.pem\"))",
        "  -> " <> shown.sent(fetch_greeting(api)),
      ]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_tls_trusted"))
      |> or_fail_with("The private authority should be trusted")
    }),
    it("step 3: another authority's file and a missing file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_983)
      let other =
        internal_api(
          certificates.port,
          certificates.other_certificate_authority,
        )
      let missing = internal_api(certificates.port, "certs/missing-ca.pem")

      // Act
      let lines = [
        "the file holds another authority   -> "
          <> shown_failure(fetch_greeting(other)),
        "the file doesn't exist             -> "
          <> shown_failure(fetch_greeting(missing)),
      ]

      // Assert
      output_file.lines(lines)
      |> should
      |> be_equal(output_file.read("guide_tls_mistakes"))
      |> or_fail_with("Both mistakes fail the connection")
    }),
    it("step 5: the client negotiates HTTP/2 over TLS", fn() {
      // Arrange
      use certificates <- tls_server.with(19_985)
      let api =
        internal_api(certificates.port, certificates.certificate_authority)
      let _response = fetch_greeting(api)

      // Act
      let protocols = connection_protocols(certificates.port)

      // Assert
      protocols
      |> should
      |> be_equal(["http2"])
      |> or_fail_with("The server offers h2, so the client uses HTTP/2")
    }),
    it("step 5: Http1Only keeps HTTP/1.1 over TLS", fn() {
      // Arrange
      use certificates <- tls_server.with(19_986)
      let api =
        internal_api(certificates.port, certificates.certificate_authority)
        |> client.protocols(client.Http1Only)
      let _response = fetch_greeting(api)

      // Act
      let protocols = connection_protocols(certificates.port)

      // Assert
      protocols
      |> should
      |> be_equal(["http"])
      |> or_fail_with("Http1Only should use HTTP/1.1")
    }),
    it("the default TLS handshake timeout is 10 seconds", fn() {
      // Act
      let milliseconds =
        client.get_tls_handshake_timeout(client.transport_config())

      // Assert
      milliseconds
      |> should
      |> be_equal(10_000)
      |> or_fail_with("The default handshake timeout is 10000 ms")
    }),
  ])
}

/// The result as the guide shows it. The reason of a TLS alert is long, so
/// it ends after `unknown_ca,`, and the full path of a missing file, which
/// differs from machine to machine, is `<the full path>`.
fn shown_failure(
  result: Result(client.HttpResponse, client.SendError),
) -> String {
  case result {
    Error(RequestError(ConnectFailed(reason: reason))) ->
      "Error(RequestError(ConnectFailed("
      <> string.inspect(shown_reason(reason))
      <> ")))"
    _ -> shown.sent(result)
  }
}

fn shown_reason(written: String) -> String {
  let unknown_ca = "{tls_alert,{unknown_ca,"
  let reason = without_line_breaks(written)
  case string.starts_with(reason, unknown_ca), string.split(reason, "\"") {
    True, _ -> unknown_ca <> "..."
    False, [before, _path, after] -> before <> "\"<the full path>\"" <> after
    False, _ -> reason
  }
}

/// The reason without the line breaks and the indentation that Erlang
/// puts in a long term. Where it breaks the term depends on the length of
/// the path, so it changes from machine to machine.
fn without_line_breaks(reason: String) -> String {
  case string.split(reason, "\n") {
    [first, ..rest] ->
      string.concat([first, ..list.map(rest, string.trim_start)])
    [] -> reason
  }
}
