//// Shared fixtures for the tests that talk to the local mock server.
////
//// The test entry point starts `dream_mock_server` on `port()` before any
//// test runs. Set `MOCK_SERVER_PORT` to use a different port.

import dream_http_client/client
import gleam/http
import gleam/int
import gleam/result

/// The port of the local mock server: `MOCK_SERVER_PORT`, or 9876.
pub fn port() -> Int {
  get_env("MOCK_SERVER_PORT", "9876")
  |> int.parse
  |> result.unwrap(9876)
}

/// A GET request to `path` on the local mock server, over plain HTTP.
pub fn get(path: String) -> client.ClientRequest {
  request(http.Get, path)
}

/// A request with `method` to `path` on the local mock server.
pub fn request(method: http.Method, path: String) -> client.ClientRequest {
  client.new()
  |> client.method(method)
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(port())
  |> client.path(path)
}

/// A GET request to a closed port (1), so the connection is refused.
pub fn closed_port(path: String) -> client.ClientRequest {
  client.new()
  |> client.method(http.Get)
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(1)
  |> client.path(path)
}

@external(erlang, "env_ffi", "get_env")
fn get_env(name: String, default: String) -> String
