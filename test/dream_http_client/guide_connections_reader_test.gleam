//// Runs the reader's test from the "Test your code" section of the
//// connections guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_connections_testing

pub fn tests() -> TestSuite {
  guide_connections_testing.tests()
}
