import dream_http_client/matching
import dream_http_client/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None, Some}

pub fn tests() -> TestSuite(Nil) {
  describe("matching.request_key keys", [
    it("builds a key from method and url ignore headers and body", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: True,
          url: True,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("GEThttps://api.example.com/users")
      |> or_fail_with("The key should be GEThttps://api.example.com/users")
    }),
    it("builds a key from only the method", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("GET")
      |> or_fail_with("The key should be GET")
    }),
    it("builds a key from only the url", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: False,
          url: True,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("https://api.example.com/users")
      |> or_fail_with("The key should be https://api.example.com/users")
    }),
    it("builds a key from only the headers", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: False,
          url: False,
          headers: True,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("Authorization:Bearer token")
      |> or_fail_with("The key should be Authorization:Bearer token")
    }),
    it("builds a key from only the body", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: False,
          url: False,
          headers: False,
          body: True,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("{}")
      |> or_fail_with("The key should be {}")
    }),
    it("builds a key from nothing", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(
          method: False,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("")
      |> or_fail_with("The key should be ")
    }),
    it("builds a key from everything", fn() {
      // Arrange
      let request =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let key =
        matching.request_key(method: True, url: True, headers: True, body: True)

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal(
        "GEThttps://api.example.com/usersAuthorization:Bearer token{}",
      )
      |> or_fail_with(
        "The key should be GEThttps://api.example.com/usersAuthorization:Bearer token{}",
      )
    }),
    it("builds a key from an http scheme", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request = recording.RecordedRequest(..request_base, scheme: http.Http)
      let key =
        matching.request_key(
          method: False,
          url: True,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("http://api.example.com/users")
      |> or_fail_with("The key should be http://api.example.com/users")
    }),
    it("builds a key from the port", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request = recording.RecordedRequest(..request_base, port: Some(8443))
      let key =
        matching.request_key(
          method: False,
          url: True,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("https://api.example.com:8443/users")
      |> or_fail_with("The key should be https://api.example.com:8443/users")
    }),
    it("builds a key from the query", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, query: Some("page=2"))
      let key =
        matching.request_key(
          method: False,
          url: True,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("https://api.example.com/users?page=2")
      |> or_fail_with("The key should be https://api.example.com/users?page=2")
    }),
    it("builds a key from headers sorted by name and joined with a bar", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, headers: [
          #("b", "2"),
          #("a", "1"),
        ])
      let key =
        matching.request_key(
          method: False,
          url: False,
          headers: True,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("a:1|b:2")
      |> or_fail_with("The key should be a:1|b:2")
    }),
    it("builds a key from the POST method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request = recording.RecordedRequest(..request_base, method: http.Post)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("POST")
      |> or_fail_with("The key should be POST")
    }),
    it("builds a key from the PUT method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request = recording.RecordedRequest(..request_base, method: http.Put)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("PUT")
      |> or_fail_with("The key should be PUT")
    }),
    it("builds a key from the DELETE method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Delete)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("DELETE")
      |> or_fail_with("The key should be DELETE")
    }),
    it("builds a key from the PATCH method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Patch)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("PATCH")
      |> or_fail_with("The key should be PATCH")
    }),
    it("builds a key from the HEAD method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request = recording.RecordedRequest(..request_base, method: http.Head)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("HEAD")
      |> or_fail_with("The key should be HEAD")
    }),
    it("builds a key from the OPTIONS method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Options)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("OPTIONS")
      |> or_fail_with("The key should be OPTIONS")
    }),
    it("builds a key from the TRACE method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Trace)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("TRACE")
      |> or_fail_with("The key should be TRACE")
    }),
    it("builds a key from the CONNECT method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Connect)
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("CONNECT")
      |> or_fail_with("The key should be CONNECT")
    }),
    it("builds a key from the PURGE method", fn() {
      // Arrange
      let request_base =
        recording.RecordedRequest(
          method: http.Get,
          scheme: http.Https,
          host: "api.example.com",
          port: None,
          path: "/users",
          query: None,
          headers: [#("Authorization", "Bearer token")],
          body: "{}",
        )
      let request =
        recording.RecordedRequest(..request_base, method: http.Other("purge"))
      let key =
        matching.request_key(
          method: True,
          url: False,
          headers: False,
          body: False,
        )

      // Act
      let value = key(request)

      // Assert
      value
      |> should
      |> be_equal("PURGE")
      |> or_fail_with("The key should be PURGE")
    }),
  ])
}
