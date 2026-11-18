import dream_http_client/client
import gleam/http
import gleam/json

pub fn create_user_request() -> client.ClientRequest {
  let json_body =
    json.object([
      #("name", json.string("Alice")),
      #("email", json.string("alice@example.com")),
    ])

  client.new()
  |> client.method(http.Post)
  |> client.body(json.to_string(json_body))
}
