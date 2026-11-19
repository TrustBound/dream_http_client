import dream_http_client/client

pub fn first_page_request() -> client.ClientRequest {
  client.new()
  |> client.path("/api/users")
  |> client.query("page=1&limit=10")
}
