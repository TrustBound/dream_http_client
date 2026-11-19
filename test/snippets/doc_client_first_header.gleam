import dream_http_client/client.{Header}

pub fn first_header(request: client.ClientRequest) -> String {
  case client.get_headers(request) {
    [Header(name, value), ..] -> name <> ": " <> value
    [] -> "No headers"
  }
}
