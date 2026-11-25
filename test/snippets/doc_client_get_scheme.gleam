import dream_http_client/client
import gleam/http.{Http}

pub fn request_scheme() -> http.Scheme {
  let request = client.new() |> client.scheme(Http)
  client.get_scheme(request)
}
