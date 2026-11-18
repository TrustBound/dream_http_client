import dream_http_client/client

pub fn request_host() -> String {
  let request = client.new() |> client.host("api.example.com")
  client.get_host(request)
}
