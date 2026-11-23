import dream_http_client/client.{
  type TransportError, ConnectFailed, Goaway, NoError, RefusedStream,
  StreamReset, TimedOut, transport_error_to_string,
}
import gleam/int

pub fn explain(error: TransportError) -> String {
  case error {
    ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    StreamReset(code: RefusedStream, ..) -> "The server refused the request"
    Goaway(code: NoError, ..) -> "The server is going away"
    _ -> transport_error_to_string(error)
  }
}
