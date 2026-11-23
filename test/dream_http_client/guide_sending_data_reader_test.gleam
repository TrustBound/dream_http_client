//// Runs the reader's test from the "Test your code" section of the
//// sending data guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_sending_data_testing

pub fn tests() -> TestSuite {
  guide_sending_data_testing.tests()
}
