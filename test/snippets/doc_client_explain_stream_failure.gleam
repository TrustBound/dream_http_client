import dream_http_client/client.{
  type StreamFailure, ConnectFailed, HttpFailure, TransportFailure,
  transport_error_to_string,
}
import gleam/int

pub fn explain_failure(failure: StreamFailure) -> String {
  case failure {
    HttpFailure(response: response) -> "HTTP " <> int.to_string(response.status)
    TransportFailure(error: ConnectFailed(reason: reason)) ->
      "Cannot connect: " <> reason
    TransportFailure(error: error) -> transport_error_to_string(error)
  }
}
