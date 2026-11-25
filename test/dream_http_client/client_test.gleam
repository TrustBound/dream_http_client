import dream_http_client/client.{Header, Http1Only, Http2Only, Http2Preferred}
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None, Some}

pub fn tests() -> TestSuite {
  describe("client request builder", [
    it("new uses GET", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_method(request)

      // Assert
      value
      |> should
      |> be_equal(http.Get)
      |> or_fail_with("new uses GET")
    }),
    it("new uses HTTPS", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_scheme(request)

      // Assert
      value
      |> should
      |> be_equal(http.Https)
      |> or_fail_with("new uses HTTPS")
    }),
    it("new uses host localhost", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_host(request)

      // Assert
      value
      |> should
      |> be_equal("localhost")
      |> or_fail_with("new uses host localhost")
    }),
    it("new sets no port", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_port(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no port")
    }),
    it("new uses an empty path", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_path(request)

      // Assert
      value
      |> should
      |> be_equal("")
      |> or_fail_with("new uses an empty path")
    }),
    it("new sets no query", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_query(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no query")
    }),
    it("new sets no headers", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_headers(request)

      // Assert
      value
      |> should
      |> be_equal([])
      |> or_fail_with("new sets no headers")
    }),
    it("new uses an empty body", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_body(request)

      // Assert
      value
      |> should
      |> be_equal(<<>>)
      |> or_fail_with("new uses an empty body")
    }),
    it("new sets no timeout", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_timeout(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no timeout")
    }),
    it("new sets no connect timeout", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_connect_timeout(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no connect timeout")
    }),
    it("new sets no auto redirect", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_auto_redirect(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no auto redirect")
    }),
    it("new sets no protocols", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_protocols(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no protocols")
    }),
    it("new sets no certificate authority file", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_certificate_authority_file(request)

      // Assert
      value
      |> should
      |> be_equal(None)
      |> or_fail_with("new sets no certificate authority file")
    }),
    it("new sets no recorder", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.get_recorder(request) |> option.is_none

      // Assert
      value
      |> should
      |> be_equal(True)
      |> or_fail_with("new sets no recorder")
    }),
    it("method sets POST", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.method(request, http.Post) |> client.get_method

      // Assert
      value
      |> should
      |> be_equal(http.Post)
      |> or_fail_with("method sets POST")
    }),
    it("scheme sets HTTP", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.scheme(request, http.Http) |> client.get_scheme

      // Assert
      value
      |> should
      |> be_equal(http.Http)
      |> or_fail_with("scheme sets HTTP")
    }),
    it("host sets the host", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.host(request, "example.com") |> client.get_host

      // Assert
      value
      |> should
      |> be_equal("example.com")
      |> or_fail_with("host sets the host")
    }),
    it("port sets the port", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.port(request, 8080) |> client.get_port

      // Assert
      value
      |> should
      |> be_equal(Some(8080))
      |> or_fail_with("port sets the port")
    }),
    it("path sets the path", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.path(request, "/api/users") |> client.get_path

      // Assert
      value
      |> should
      |> be_equal("/api/users")
      |> or_fail_with("path sets the path")
    }),
    it("query sets the query", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.query(request, "name=value") |> client.get_query

      // Assert
      value
      |> should
      |> be_equal(Some("name=value"))
      |> or_fail_with("query sets the query")
    }),
    it("headers replaces the headers", fn() {
      // Arrange
      let request = client.new() |> client.add_header("X-Old", "1")

      // Act
      let value =
        client.headers(request, [Header("Authorization", "Bearer token")])
        |> client.get_headers

      // Assert
      value
      |> should
      |> be_equal([Header("Authorization", "Bearer token")])
      |> or_fail_with("headers replaces the headers")
    }),
    it("body sets the body", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.body(request, "{\"key\":\"value\"}") |> client.get_body

      // Assert
      value
      |> should
      |> be_equal(<<"{\"key\":\"value\"}">>)
      |> or_fail_with("body sets the body")
    }),
    it("timeout sets the timeout", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.timeout(request, 60_000) |> client.get_timeout

      // Assert
      value
      |> should
      |> be_equal(Some(60_000))
      |> or_fail_with("timeout sets the timeout")
    }),
    it("connect_timeout sets the connect timeout", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.connect_timeout(request, 5000) |> client.get_connect_timeout

      // Assert
      value
      |> should
      |> be_equal(Some(5000))
      |> or_fail_with("connect_timeout sets the connect timeout")
    }),
    it("connect_timeout accepts zero", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.connect_timeout(request, 0) |> client.get_connect_timeout

      // Assert
      value
      |> should
      |> be_equal(Some(0))
      |> or_fail_with("connect_timeout accepts zero")
    }),
    it("auto_redirect sets False", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.auto_redirect(request, False) |> client.get_auto_redirect

      // Assert
      value
      |> should
      |> be_equal(Some(False))
      |> or_fail_with("auto_redirect sets False")
    }),
    it("auto_redirect sets True", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.auto_redirect(request, True) |> client.get_auto_redirect

      // Assert
      value
      |> should
      |> be_equal(Some(True))
      |> or_fail_with("auto_redirect sets True")
    }),
    it("add_header adds a header", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.add_header(request, "X-Custom", "value") |> client.get_headers

      // Assert
      value
      |> should
      |> be_equal([Header("X-Custom", "value")])
      |> or_fail_with("add_header adds a header")
    }),
    it("add_header puts the newest header first", fn() {
      // Arrange
      let request = client.new() |> client.add_header("X-First", "1")

      // Act
      let value =
        client.add_header(request, "X-Second", "2") |> client.get_headers

      // Assert
      value
      |> should
      |> be_equal([Header("X-Second", "2"), Header("X-First", "1")])
      |> or_fail_with("add_header puts the newest header first")
    }),
    it("protocols sets Http2Only", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.protocols(request, Http2Only) |> client.get_protocols

      // Assert
      value
      |> should
      |> be_equal(Some(Http2Only))
      |> or_fail_with("protocols sets Http2Only")
    }),
    it("protocols sets Http1Only", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value = client.protocols(request, Http1Only) |> client.get_protocols

      // Assert
      value
      |> should
      |> be_equal(Some(Http1Only))
      |> or_fail_with("protocols sets Http1Only")
    }),
    it("protocols sets Http2Preferred", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.protocols(request, Http2Preferred) |> client.get_protocols

      // Assert
      value
      |> should
      |> be_equal(Some(Http2Preferred))
      |> or_fail_with("protocols sets Http2Preferred")
    }),
    it("certificate_authority_file sets the path", fn() {
      // Arrange
      let request = client.new()

      // Act
      let value =
        client.certificate_authority_file(request, "/etc/ssl/ca.pem")
        |> client.get_certificate_authority_file

      // Assert
      value
      |> should
      |> be_equal(Some("/etc/ssl/ca.pem"))
      |> or_fail_with("certificate_authority_file sets the path")
    }),
  ])
}
