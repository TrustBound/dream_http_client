import dream_http_client/client

pub fn local_request() -> client.ClientRequest {
  client.new()
  |> client.host("localhost")
  |> client.port(3000)
}
