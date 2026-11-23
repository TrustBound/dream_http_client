//// Tests for the snippets of the TLS guide
//// (docs/guides/tls-and-certificate-authorities.md). Each test starts a
//// TLS server with test certificates on its own port, and asserts the
//// exact value that the guide shows.

import dream_http_client/client.{ConnectFailed, RequestError}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{connection_protocols}
import fixtures/tls_server
import gleam/list
import gleam/result
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
      let starts_with_unknown_ca =
        fetch_greeting(request) |> reason_starts_with("{tls_alert,{unknown_ca,")

      // Assert
      starts_with_unknown_ca
      |> should
      |> be_equal(True)
      |> or_fail_with("The handshake should fail with unknown_ca")
    }),
    it("step 2: internal_api trusts the private authority", fn() {
      // Arrange
      use certificates <- tls_server.with(19_982)
      let api =
        internal_api(certificates.port, certificates.certificate_authority)

      // Act
      let greeting =
        fetch_greeting(api)
        |> result.map(fn(response) { #(response.status, response.body) })

      // Assert
      greeting
      |> should
      |> be_equal(Ok(#(200, <<"hello over tls">>)))
      |> or_fail_with("The private authority should be trusted")
    }),
    it("step 3: another authority's file is rejected", fn() {
      // Arrange
      use certificates <- tls_server.with(19_983)
      let api =
        internal_api(
          certificates.port,
          certificates.other_certificate_authority,
        )

      // Act
      let starts_with_unknown_ca =
        fetch_greeting(api) |> reason_starts_with("{tls_alert,{unknown_ca,")

      // Assert
      starts_with_unknown_ca
      |> should
      |> be_equal(True)
      |> or_fail_with("Another authority should not be trusted")
    }),
    it("step 3: a missing file fails the connection", fn() {
      // Arrange
      use certificates <- tls_server.with(19_984)
      let api = internal_api(certificates.port, "certs/missing-ca.pem")

      // Act
      let names_the_file =
        fetch_greeting(api)
        |> reason_contains(["certs/missing-ca.pem", "{error,enoent}"])

      // Assert
      names_the_file
      |> should
      |> be_equal(True)
      |> or_fail_with("The reason should name the file and enoent")
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

fn reason_starts_with(
  result: Result(client.HttpResponse, client.SendError),
  prefix: String,
) -> Bool {
  case result {
    Error(RequestError(ConnectFailed(reason: reason))) ->
      string.starts_with(reason, prefix)
    _ -> False
  }
}

fn reason_contains(
  result: Result(client.HttpResponse, client.SendError),
  parts: List(String),
) -> Bool {
  case result {
    Error(RequestError(ConnectFailed(reason: reason))) ->
      list.all(parts, string.contains(reason, _))
    _ -> False
  }
}
