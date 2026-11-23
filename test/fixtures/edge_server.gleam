//// A test server that sends server edge cases: trailers, stalled bodies,
//// empty bodies, closed connections, redirect loops, and HTTP/2
//// RST_STREAM, GOAWAY and connection errors. See `edge_server_ffi.erl` for the scenarios.

import dream_http_client/client
import gleam/erlang/process
import gleam/http
import gleam/int

/// Start a server for `scenario` on a free port, call `body` with the port,
/// then stop the server and its connections.
pub fn with(scenario: String, body: fn(Int) -> a) -> a {
  let server = start(scenario)
  let result = body(server.0)
  stop(server)
  result
}

/// Start a TLS server for an `h2s_` scenario that offers only h2 with ALPN,
/// call `body` with a `GET https://localhost:<port>/` request that trusts
/// the test certificate authority, then stop the server.
pub fn with_tls(scenario: String, body: fn(client.ClientRequest) -> a) -> a {
  // New files for each server: Erlang's ssl caches certificate files by
  // path, so a second server must not reuse the paths of the first.
  let #(certfile, keyfile, certificate_authority, _other) =
    write_certificates(
      "build/test_tls/edge_"
      <> scenario
      <> "_"
      <> int.to_string(unique_integer([Positive])),
    )
  let server = start_tls(scenario, certfile, keyfile)
  let request =
    request(server.0)
    |> client.scheme(http.Https)
    |> client.certificate_authority_file(certificate_authority)
  let result = body(request)
  stop(server)
  result
}

/// A `GET http://localhost:<port>/` request.
pub fn request(port: Int) -> client.ClientRequest {
  client.new()
  |> client.method(http.Get)
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(port)
  |> client.path("/")
}

/// Wait until the client has a connection to `port` with a request on it,
/// then kill the connection process. Returns the number of killed
/// connections.
@external(erlang, "edge_server_ffi", "kill_connections")
pub fn kill_connections(port: Int) -> Int

/// True when the `flood` server on `port` sent its whole 64 MB body. The
/// body is larger than the socket buffers, so the server can send all of it
/// only while the client keeps reading.
@external(erlang, "edge_server_ffi", "flood_sent")
pub fn flood_sent(port: Int) -> Bool

/// The number of HTTP/1.1 requests, and of `h2_` HTTP/2 requests, that the
/// server on `port` read.
@external(erlang, "edge_server_ffi", "requests_received")
pub fn requests_received(port: Int) -> Int

/// As `kill_connections`, but the connection processes stop with the
/// reason `shutdown`, as a connection does that lost its socket.
@external(erlang, "edge_server_ffi", "stop_connections")
pub fn stop_connections(port: Int) -> Int

/// Suspend the connection processes to `port`, so a request sent to them
/// waits in their mailbox. Returns the number of suspended connections.
@external(erlang, "edge_server_ffi", "suspend_connections")
pub fn suspend_connections(port: Int) -> Int

/// As `stop_connections`, but the connection processes stop with the reason
/// `{shutdown, closed}`, as gun stops by itself after it lost its socket.
@external(erlang, "edge_server_ffi", "lose_connections")
pub fn lose_connections(port: Int) -> Int

@external(erlang, "edge_server_ffi", "start")
fn start(scenario: String) -> #(Int, process.Pid)

@external(erlang, "edge_server_ffi", "start_tls")
fn start_tls(
  scenario: String,
  certfile: String,
  keyfile: String,
) -> #(Int, process.Pid)

type UniqueOption {
  Positive
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

@external(erlang, "certificate_authority_ffi", "write_certificates")
fn write_certificates(directory: String) -> #(String, String, String, String)

@external(erlang, "edge_server_ffi", "stop")
fn stop(server: #(Int, process.Pid)) -> Nil
