import dream_http_client/client.{HttpResponse}
import gleam/bit_array
import gleam/int

pub fn describe_response(request: client.ClientRequest) -> String {
  case client.send(request) {
    Ok(HttpResponse(status: 200, body: body, ..)) ->
      "OK: " <> int.to_string(bit_array.byte_size(body)) <> " bytes"
    Ok(HttpResponse(status: status, ..)) -> "Status " <> int.to_string(status)
    Error(_) -> "Request failed"
  }
}
