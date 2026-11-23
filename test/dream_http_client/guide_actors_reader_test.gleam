//// Runs the reader's test from the "Test your code" section of the
//// streaming to actors guide, as the guide shows it.

import dream_test/suite.{type TestSuite}
import snippets/guide_actors_testing

pub fn tests() -> TestSuite {
  guide_actors_testing.tests()
}
