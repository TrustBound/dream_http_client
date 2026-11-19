import dream_http_client/client
import gleam/http.{Post}

pub fn request_method() -> http.Method {
  let request = client.new() |> client.method(Post)
  client.get_method(request)
}
