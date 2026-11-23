//// Stop and start the application and its connection manager, and read
//// state that the public API does not show. See `application_ffi.erl`.

/// Stop and start the `dream_http_client` application.
@external(erlang, "application_ffi", "restart_application")
pub fn restart_application() -> Nil

/// Kill the connection manager and wait until its supervisor starts a new
/// one. The new manager reads the idle timeout of the transport config.
@external(erlang, "application_ffi", "restart_connection_manager")
pub fn restart_connection_manager() -> Nil

/// The log level of `dream_http_client_log`, the module that writes every
/// log line of the client, for example `"info"`.
@external(erlang, "application_ffi", "client_log_level")
pub fn client_log_level() -> String

/// Send a cast and a plain message that the connection manager does not
/// know.
@external(erlang, "application_ffi", "send_unknown_messages")
pub fn send_unknown_messages() -> Nil

/// The number of open connections in the connection table.
@external(erlang, "application_ffi", "connection_count")
pub fn connection_count() -> Int

/// The number of leases that the connection manager holds: one for each
/// request or stream that has a connection and did not give it back.
@external(erlang, "application_ffi", "lease_count")
pub fn lease_count() -> Int

/// The protocol of each open connection to `port`, sorted: `"http"` for
/// HTTP/1.1 and `"http2"` for HTTP/2.
@external(erlang, "application_ffi", "connection_protocols")
pub fn connection_protocols(port: Int) -> List(String)
