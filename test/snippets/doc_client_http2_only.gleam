import dream_http_client/client.{Http2Only}
import gleam/http

pub fn http2_only_request() -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("internal-service.local")
  |> client.protocols(Http2Only)
}
