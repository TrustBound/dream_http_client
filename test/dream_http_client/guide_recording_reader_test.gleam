//// Runs the reader's test from the "Test your code" section of the
//// recording guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_recording_testing

pub fn tests() -> TestSuite {
  guide_recording_testing.tests()
}
