import dream_http_client/client
import gleam/option.{type Option}

pub fn request_timeout() -> Option(Int) {
  let request = client.new() |> client.timeout(5000)
  client.get_timeout(request)
}
