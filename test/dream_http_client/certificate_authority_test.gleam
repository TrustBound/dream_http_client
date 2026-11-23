//// Certificate authority settings over HTTPS
////
//// Each test starts a Dream server with a test certificate signed by a test
//// certificate authority, then checks which requests trust it. Covers the
//// per-request setting, the client-wide default, and all three execution
//// modes (send, stream_yielder, start_stream).

import dream_http_client/client.{Http2Only}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/mailbox
import fixtures/tls_server
import gleam/bytes_tree
import gleam/erlang/process
import gleam/result
import gleam/yielder

pub fn tests() -> TestSuite {
  describe("certificate authority", [
    it("send trusts a server signed by the certificate authority file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_960)
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file(certificates.certificate_authority)

      // Act
      let body = client.send(request) |> result.map(fn(r) { r.body })

      // Assert
      body
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("The server should be trusted")
    }),
    it("send rejects a server from an unknown certificate authority", fn() {
      // Arrange
      use certificates <- tls_server.with(19_961)
      let request = tls_server.request(certificates.port)

      // Act
      let failed = client.send(request) |> result.is_error

      // Assert
      failed
      |> should
      |> be_equal(True)
      |> or_fail_with("A server from an unknown authority should be rejected")
    }),
    it("send rejects a server from another certificate authority", fn() {
      // Arrange
      use certificates <- tls_server.with(19_962)
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file(
          certificates.other_certificate_authority,
        )

      // Act
      let failed = client.send(request) |> result.is_error

      // Assert
      failed
      |> should
      |> be_equal(True)
      |> or_fail_with("A server from another authority should be rejected")
    }),
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
    it("send fails when the certificate authority file is missing", fn() {
      // Arrange
      use certificates <- tls_server.with(19_965)
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file("build/test_tls/missing.pem")

      // Act
      let failed = client.send(request) |> result.is_error

      // Assert
      failed
      |> should
      |> be_equal(True)
      |> or_fail_with("A missing authority file should fail the request")
    }),
    it("send uses HTTP/2 over TLS with the certificate authority file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_966)
      let request =
        tls_server.request(certificates.port)
        |> client.protocols(Http2Only)
        |> client.certificate_authority_file(certificates.certificate_authority)

      // Act
      let body = client.send(request) |> result.map(fn(r) { r.body })

      // Assert
      body
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("HTTP/2 over TLS should trust the server")
    }),
    it("stream_yielder trusts the certificate authority file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_967)
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file(certificates.certificate_authority)

      // Act
      let body =
        client.stream_yielder(request)
        |> yielder.to_list
        |> result.all
        |> result.map(fn(chunks) {
          bytes_tree.concat(chunks) |> bytes_tree.to_bit_array
        })

      // Assert
      body
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("The stream should trust the server")
    }),
    it("start_stream trusts the certificate authority file", fn() {
      // Arrange
      use certificates <- tls_server.with(19_968)
      let chunks = process.new_subject()
      let ended = process.new_subject()
      let request =
        tls_server.request(certificates.port)
        |> client.certificate_authority_file(certificates.certificate_authority)
        |> client.on_stream_chunk(fn(data) { process.send(chunks, data) })
        |> client.on_stream_end(fn(_headers) { process.send(ended, True) })
        |> client.on_stream_error(fn(_failure) { process.send(ended, False) })
      let assert Ok(_handle) = client.start_stream(request)

      // Act
      let end = process.receive(ended, 10_000)
      let body = mailbox.drain_bits(chunks)

      // Assert
      #(end, body)
      |> should
      |> be_equal(#(Ok(True), <<"hello over tls">>))
      |> or_fail_with("The stream callbacks should get the body")
    }),
  ])
}
