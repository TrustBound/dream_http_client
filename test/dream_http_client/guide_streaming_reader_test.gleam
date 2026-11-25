//// Runs the reader's test from the "Test your streaming code" section of
//// the streaming guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_streaming_testing

pub fn tests() -> TestSuite {
  guide_streaming_testing.tests()
}
