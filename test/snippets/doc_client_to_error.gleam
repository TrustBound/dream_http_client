import dream_errors.{kind_name, message}
import dream_http_client/client.{type TransportError, to_error}

pub fn log_line(error: TransportError) -> String {
  let shared = to_error(error)
  kind_name(shared) <> ": " <> message(shared)
}
