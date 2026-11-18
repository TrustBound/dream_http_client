import dream_http_client/client

pub fn request_headers() -> List(client.Header) {
  let request =
    client.new()
    |> client.add_header("Authorization", "Bearer token")
    |> client.add_header("Content-Type", "application/json")
  client.get_headers(request)
}
