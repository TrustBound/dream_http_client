import dream_http_client/client.{
  type TransportError, ConnectFailed, StreamReset, TimedOut,
  transport_error_to_string,
}
import gleam/int

pub fn explain(error: TransportError) -> String {
  case error {
    ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    StreamReset(code: code, description: description) ->
      "Stream reset: " <> code <> " - " <> description
    _ -> transport_error_to_string(error)
  }
}
