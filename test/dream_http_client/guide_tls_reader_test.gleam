//// Runs the reader's test from the "Test your code" section of the TLS
//// guide, as the guide shows it, with certificate files that this test
//// writes.

import dream_test/suite.{type TestSuite}
import snippets/guide_tls_testing.{TestFiles}

pub fn tests() -> TestSuite {
  let #(certfile, keyfile, ca_file, _other) =
    write_certificates("build/test_tls/guide_tls_reader")
  guide_tls_testing.tests_with(TestFiles(certfile:, keyfile:, ca_file:))
}

@external(erlang, "certificate_authority_ffi", "write_certificates")
fn write_certificates(directory: String) -> #(String, String, String, String)
