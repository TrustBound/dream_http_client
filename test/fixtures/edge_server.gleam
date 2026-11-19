//// A test server that sends server edge cases: trailers, stalled bodies,
//// closed connections, redirect loops, and HTTP/2 RST_STREAM, GOAWAY and
//// connection errors. See `edge_server_ffi.erl` for the scenarios.

import dream_http_client/client
import gleam/erlang/process
import gleam/http

/// Start a server for `scenario` on a free port, call `body` with the port,
/// then stop the server and its connections.
pub fn with(scenario: String, body: fn(Int) -> a) -> a {
  let server = start(scenario)
  let result = body(server.0)
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

@external(erlang, "edge_server_ffi", "start")
fn start(scenario: String) -> #(Int, process.Pid)

@external(erlang, "edge_server_ffi", "stop")
fn stop(server: #(Int, process.Pid)) -> Nil
