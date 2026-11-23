//// A mist server over TLS, with test certificates, for the certificate
//// authority tests.

import dream_http_client/client
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import mist

/// The certificate files of one test server.
pub type Certificates {
  Certificates(
    port: Int,
    certificate_authority: String,
    other_certificate_authority: String,
  )
}

/// Start a TLS server on `localhost:<port>` that answers `GET /tls` with
/// `hello over tls`, `GET /tls/slow` with the same text after 300 ms, and
/// any other request with status 404. The server offers HTTP/2 through ALPN.
/// Run `body`, stop the server, and return what `body` returned. The port is
/// closed when this function returns. Each port gets its own certificates,
/// so one test never reuses the server or the pooled connection of another
/// test.
pub fn with(port: Int, body: fn(Certificates) -> a) -> a {
  let #(certfile, keyfile, certificate_authority, other) =
    write_certificates("build/test_tls/" <> int.to_string(port))
  let assert Ok(started) =
    mist.new(handle)
    |> mist.bind("localhost")
    |> mist.port(port)
    |> mist.with_tls(certfile:, keyfile:)
    |> mist.start
  let result = body(Certificates(port, certificate_authority, other))
  stop_supervisor(started.pid)
  result
}

/// Run `body` with `path` as the client-wide default certificate authority
/// file, then put the default transport configuration back.
pub fn with_default_certificate_authority_file(
  path: String,
  body: fn() -> a,
) -> a {
  client.transport_config()
  |> client.default_certificate_authority_file(path)
  |> client.configure_transport()
  let result = body()
  client.configure_transport(client.transport_config())
  result
}

/// A GET request to `https://localhost:<port>/tls`.
pub fn request(port: Int) -> client.ClientRequest {
  client.new()
  |> client.method(http.Get)
  |> client.scheme(http.Https)
  |> client.host("localhost")
  |> client.port(port)
  |> client.path("/tls")
}

fn handle(request: Request(mist.Connection)) -> Response(mist.ResponseData) {
  case request.method, request.path {
    http.Get, "/tls" -> hello()
    http.Get, "/tls/slow" -> {
      process.sleep(300)
      hello()
    }
    _, _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn hello() -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("hello over tls")))
}

@external(erlang, "certificate_authority_ffi", "write_certificates")
fn write_certificates(directory: String) -> #(String, String, String, String)

@external(erlang, "certificate_authority_ffi", "stop_supervisor")
fn stop_supervisor(supervisor: process.Pid) -> Nil
