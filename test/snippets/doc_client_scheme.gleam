import dream_http_client/client
import gleam/http

pub fn plain_http_request() -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
}
