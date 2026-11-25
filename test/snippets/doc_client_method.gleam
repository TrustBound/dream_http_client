import dream_http_client/client
import gleam/http

pub fn post_request() -> client.ClientRequest {
  client.new()
  |> client.method(http.Post)
}
