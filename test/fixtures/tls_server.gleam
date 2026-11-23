//// A Dream server over TLS, with test certificates, for the certificate
//// authority tests.

import dream/http/request as dream_request
import dream/http/response as dream_response
import dream/router
import dream/servers/mist/server
import dream_http_client/client
import gleam/erlang/process
import gleam/http
import gleam/int

/// The certificate files of one test server.
pub type Certificates {
  Certificates(
    port: Int,
    certificate_authority: String,
    other_certificate_authority: String,
  )
}

/// Start a TLS server on `port` that answers `GET /tls` with
/// `hello over tls`, and `GET /tls/slow` with the same text after 300 ms,
/// run `body`, stop the server, and return what `body`
/// returned. Each port gets its own certificates, so one test never reuses
/// the server or the pooled connection of another test.
pub fn with(port: Int, body: fn(Certificates) -> a) -> a {
  let #(certfile, keyfile, certificate_authority, other) =
    write_certificates("build/test_tls/" <> int.to_string(port))
  let assert Ok(handle) =
    server.new()
    |> server.router(
      router.router()
      |> router.route(
        method: dream_request.Get,
        path: "/tls",
        controller: hello,
        middleware: [],
      )
      |> router.route(
        method: dream_request.Get,
        path: "/tls/slow",
        controller: slow_hello,
        middleware: [],
      ),
    )
    |> server.tls(certfile:, keyfile:)
    |> server.listen_with_handle(port)
  let result = body(Certificates(port, certificate_authority, other))
  server.stop(handle)
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

fn hello(_request, _context, _services) {
  dream_response.text_response(200, "hello over tls")
}

fn slow_hello(_request, _context, _services) {
  process.sleep(300)
  dream_response.text_response(200, "hello over tls")
}

@external(erlang, "certificate_authority_ffi", "write_certificates")
fn write_certificates(directory: String) -> #(String, String, String, String)
