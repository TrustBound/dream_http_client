import dream_http_client/client.{Http2Only}
import gleam/option.{type Option}

pub fn request_protocols() -> Option(client.Protocols) {
  let request = client.new() |> client.protocols(Http2Only)
  client.get_protocols(request)
}
