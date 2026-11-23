import dream_http_client/client

pub fn text_of(response: client.HttpResponse) -> String {
  case client.body_text(response) {
    Ok(text) -> text
    Error(Nil) -> "The body is not text"
  }
}
