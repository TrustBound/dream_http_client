//// Tests for the default certificate authority step of the TLS guide
//// (docs/guides/tls-and-certificate-authorities.md). They change the
//// global transport configuration, so they run with the lifecycle suites,
//// one test at a time.

import dream_http_client/client.{ConnectFailed, RequestError}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/application.{restart_application}
import fixtures/tls_server
import gleam/result
import gleam/string
import snippets/guide_tls_default.{trust_company_ca}
import snippets/guide_tls_request.{fetch_greeting, internal_api}

pub fn tests() -> TestSuite {
  describe("TLS guide, default certificate authority", [
    it("step 4: a request with no file trusts the default", fn() {
      // Arrange
      restart_application()
      use certificates <- tls_server.with(19_988)
      trust_company_ca(certificates.certificate_authority)
      let api =
        client.new()
        |> client.host("localhost")
        |> client.port(certificates.port)

      // Act
      let greeting =
        fetch_greeting(api) |> result.map(fn(response) { response.body })
      client.configure_transport(client.transport_config())

      // Assert
      greeting
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("The default authority should be trusted")
    }),
    it("step 4: the file of the request wins over the default", fn() {
      // Arrange
      restart_application()
      use certificates <- tls_server.with(19_989)
      trust_company_ca(certificates.certificate_authority)
      let api =
        internal_api(
          certificates.port,
          certificates.other_certificate_authority,
        )

      // Act
      let rejected = case fetch_greeting(api) {
        Error(RequestError(ConnectFailed(reason: reason))) ->
          string.starts_with(reason, "{tls_alert,{unknown_ca,")
        _ -> False
      }
      client.configure_transport(client.transport_config())

      // Assert
      rejected
      |> should
      |> be_equal(True)
      |> or_fail_with("The request's own file replaces the default")
    }),
  ])
}
