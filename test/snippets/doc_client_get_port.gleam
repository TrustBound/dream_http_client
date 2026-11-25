import dream_http_client/client
import gleam/option.{type Option}

pub fn request_port() -> Option(Int) {
  let request = client.new() |> client.port(8080)
  client.get_port(request)
}
