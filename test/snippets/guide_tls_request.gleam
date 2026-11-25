//// Guide: Calling a service with a private certificate authority, steps 1
//// and 2
////
//// Calls an internal HTTPS service whose certificate a private
//// certificate authority signed.

import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError,
  certificate_authority_file, host, path, port, send,
}

/// The base request of the internal service. Every request to it trusts
/// the certificate authority in `ca_file`, and only that one.
pub fn internal_api(service_port: Int, ca_file: String) -> ClientRequest {
  client.new()
  |> host("localhost")
  |> port(service_port)
  |> certificate_authority_file(ca_file)
}

pub fn fetch_greeting(api: ClientRequest) -> Result(HttpResponse, SendError) {
  api
  |> path("/tls")
  |> send()
}
