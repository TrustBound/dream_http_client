import dream_http_client/client.{get_host, get_path, host, path}

pub fn describe_target() -> String {
  let request = client.new() |> host("api.example.com") |> path("/users/123")
  "Calling: " <> get_host(request) <> get_path(request)
}
