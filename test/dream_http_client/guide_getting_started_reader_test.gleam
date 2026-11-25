//// Runs the reader's test from the "Test your code" section of the
//// getting started guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_getting_started_testing

pub fn tests() -> TestSuite {
  guide_getting_started_testing.tests()
}
