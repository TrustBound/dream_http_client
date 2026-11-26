import dream_errors
import dream_http_client/client.{type TransportError}

pub fn log_line(error: TransportError) -> String {
  let shared = client.to_error(error)
  dream_errors.kind_name(shared) <> ": " <> dream_errors.message(shared)
}
