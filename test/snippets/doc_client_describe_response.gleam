import dream_http_client/client.{HttpResponse}
import gleam/int

pub fn describe_response(request: client.ClientRequest) -> String {
  case client.send(request) {
    Ok(HttpResponse(status: 200, body: body, ..)) -> "OK: " <> body
    Ok(HttpResponse(status: status, ..)) -> "Status " <> int.to_string(status)
    Error(_) -> "Request failed"
  }
}
