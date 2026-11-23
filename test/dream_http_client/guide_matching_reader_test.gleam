//// Runs the reader's test from the "Test your code" section of the
//// request matching guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_matching_testing

pub fn tests() -> TestSuite {
  guide_matching_testing.tests()
}
