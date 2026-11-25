import dream_http_client/client
import gleam/option.{type Option}

pub fn request_query() -> Option(String) {
  let request = client.new() |> client.query("page=1&limit=10")
  client.get_query(request)
}
