import dream_http_client/client
import gleam/option.{type Option}

pub fn internal_request() -> client.ClientRequest {
  client.new()
  |> client.host("internal.example.com")
  |> client.certificate_authority_file("certs/internal-ca.pem")
  |> client.connect_timeout(2000)
  |> client.auto_redirect(False)
}

pub fn request_settings(
  request: client.ClientRequest,
) -> #(Option(String), Option(Int), Option(Bool)) {
  #(
    client.get_certificate_authority_file(request),
    client.get_connect_timeout(request),
    client.get_auto_redirect(request),
  )
}
