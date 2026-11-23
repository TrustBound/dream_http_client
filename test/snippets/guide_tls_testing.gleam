//// Guide: Calling a service with a private certificate authority, testing
////
//// Tests fetch_greeting against a local HTTPS server whose certificate the
//// test certificate authority signed.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/result
import mist
import snippets/guide_tls_request.{fetch_greeting, internal_api}

/// The test certificate files: the server's certificate and key, and the
/// certificate authority that signed the certificate for "localhost".
pub type TestFiles {
  TestFiles(certfile: String, keyfile: String, ca_file: String)
}

pub fn tests_with(files: TestFiles) -> TestSuite {
  describe("internal API over TLS", [
    it("trusts the server of the test certificate authority", fn() {
      // Arrange
      let assert Ok(server) =
        mist.new(answer)
        |> mist.bind("localhost")
        |> mist.port(19_987)
        |> mist.with_tls(certfile: files.certfile, keyfile: files.keyfile)
        |> mist.start

      // Act
      let greeting =
        fetch_greeting(internal_api(19_987, files.ca_file))
        |> result.map(fn(response) { response.body })
      process.unlink(server.pid)
      process.kill(server.pid)

      // Assert
      greeting
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("Expected the greeting over TLS")
    }),
  ])
}

fn answer(_request: Request(mist.Connection)) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("hello over tls")))
}
