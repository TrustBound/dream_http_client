import dream_http_client/client.{Header}

pub fn json_api_request(token: String) -> client.ClientRequest {
  client.new()
  |> client.headers([
    Header("Authorization", "Bearer " <> token),
    Header("Content-Type", "application/json"),
  ])
}
