import dream_http_client/client

pub fn json_api_request(token: String) -> client.ClientRequest {
  client.new()
  |> client.add_header("Authorization", "Bearer " <> token)
  |> client.add_header("Content-Type", "application/json")
}
