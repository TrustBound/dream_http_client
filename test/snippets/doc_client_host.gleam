import dream_http_client/client

pub fn api_request() -> client.ClientRequest {
  client.new()
  |> client.host("api.example.com")
}
