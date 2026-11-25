import dream_http_client/matching
import dream_http_client/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import fixtures/recorded
import gleam/http

pub fn tests() -> TestSuite {
  describe("matching.request_key", [
    it("gives the same key when only the header order differs", fn() {
      // Arrange
      let key =
        matching.request_key(
          method: True,
          url: True,
          headers: True,
          body: False,
        )
      let first =
        recording.RecordedRequest(..recorded.text_request(), headers: [
          #("b", "2"),
          #("a", "1"),
        ])
      let second =
        recording.RecordedRequest(..recorded.text_request(), headers: [
          #("a", "1"),
          #("b", "2"),
        ])

      // Act
      let keys = #(key(first), key(second))

      // Assert
      keys.0
      |> should
      |> be_equal(keys.1)
      |> or_fail_with("Header order should not change the key")
    }),
    it(
      "gives a lowercase Other method the same key as the standard method",
      fn() {
        // Arrange
        let key =
          matching.request_key(
            method: True,
            url: True,
            headers: False,
            body: False,
          )
        let standard = recorded.text_request()
        let other =
          recording.RecordedRequest(
            ..recorded.text_request(),
            method: http.Other("get"),
          )

        // Act
        let keys = #(key(standard), key(other))

        // Assert
        keys.0
        |> should
        |> be_equal(keys.1)
        |> or_fail_with("Other(\"get\") should key the same as Get")
      },
    ),
  ])
}
