import dream_http_client/client
import gleam/http

pub fn upload_request(file: BitArray) -> client.ClientRequest {
  client.new()
  |> client.method(http.Put)
  |> client.host("files.example.com")
  |> client.path("/reports/2026.pdf")
  |> client.add_header("Content-Type", "application/pdf")
  |> client.body_bits(file)
}
