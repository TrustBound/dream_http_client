//// Runs the reader's test from the "Test your code" section of the
//// errors guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_errors_testing

pub fn tests() -> TestSuite {
  guide_errors_testing.tests()
}
