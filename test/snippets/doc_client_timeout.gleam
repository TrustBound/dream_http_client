import dream_http_client/client.{host, timeout}

pub fn slow_request() -> client.ClientRequest {
  client.new()
  |> host("slow-api.example.com")
  |> timeout(60_000)
}
