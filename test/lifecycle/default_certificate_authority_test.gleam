//// Tests of the client-wide default certificate authority file over
//// HTTPS. The default is part of the global transport configuration, so
//// these tests run with the lifecycle suites, one test at a time: a test
//// beside them that sends with no file would trust the default too.
//// `tls_server.with_default_certificate_authority_file` puts the default
//// configuration back.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/tls_server
import gleam/result

pub fn tests() -> TestSuite {
  describe("default certificate authority", [
    it("send uses the default certificate authority file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_963)
      use <- tls_server.with_default_certificate_authority_file(
        certificates.certificate_authority,
      )
      let request = tls_server.request(certificates.port)

      // Act
      let body = client.send(request) |> result.map(fn(r) { r.body })

      // Assert
      body
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("The default authority file should be used")
    }),
    it("the request file wins over the default file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_964)
      use <- tls_server.with_default_certificate_authority_file(
        certificates.other_certificate_authority,
      )
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file(certificates.certificate_authority)

      // Act
      let body = client.send(request) |> result.map(fn(r) { r.body })

      // Assert
      body
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("The request authority file should win")
    }),
  ])
}
