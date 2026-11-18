import dream_http_client/client

pub fn user_request() -> client.ClientRequest {
  client.new()
  |> client.path("/api/users/123")
}
