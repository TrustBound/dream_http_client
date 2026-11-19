import dream_http_client/client

pub fn request_path() -> String {
  let request = client.new() |> client.path("/api/users")
  client.get_path(request)
}
