import dream_http_client/client.{
  ConnectFailed, RequestError, ResponseError, transport_error_to_string,
}
import gleam/int

pub fn send_and_describe(request: client.ClientRequest) -> String {
  case client.send(request) {
    Ok(response) -> "Got " <> int.to_string(response.status)
    Error(ResponseError(response: response)) ->
      "HTTP " <> int.to_string(response.status)
    Error(RequestError(error: ConnectFailed(reason: reason))) ->
      "Cannot connect: " <> reason
    Error(RequestError(error: error)) ->
      "Failed: " <> transport_error_to_string(error)
  }
}
