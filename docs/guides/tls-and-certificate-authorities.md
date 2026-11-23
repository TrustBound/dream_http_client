# TLS and certificate authorities

This guide shows how to trust a private certificate authority over HTTPS, for one request or for all requests.

## The default

Over HTTPS, the client checks the certificate of the server against the system certificate authorities.

## Trust a private certificate authority for one request

`certificate_authority_file(path)` makes the request trust the certificate authorities in the PEM file at `path` in place of the system certificate authorities, the same as `curl --cacert`. Use it for services with a private certificate authority, and for test servers with their own certificate.

- This setting wins over `default_certificate_authority_file()`.
- Requests with different settings never share a connection.
- Plain HTTP requests ignore it.
- If the file cannot be read, the request fails with a transport error.

### Read the request settings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
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
```

## Trust a private certificate authority for all requests

`default_certificate_authority_file(path)` on the transport configuration makes every request trust the certificate authorities in the PEM file at `path` in place of the system certificate authorities, unless the request sets its own with `certificate_authority_file()`. The default is none: requests trust the system certificate authorities. `get_default_certificate_authority_file(config)` returns `None` in that case.

### Tune the transport <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_transport_tuning.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client

pub fn tuned_transport() -> client.TransportConfig {
  client.transport_config()
  |> client.max_connections(100)
  |> client.idle_timeout(30_000)
  |> client.default_connect_timeout(5000)
  |> client.domain_lookup_timeout(2000)
  |> client.tls_handshake_timeout(5000)
  |> client.keepalive(10_000)
  |> client.keepalive_tolerance(3)
  |> client.max_concurrent_streams(200)
  |> client.initial_connection_window_size(1_048_576)
  |> client.initial_stream_window_size(262_144)
  |> client.closing_timeout(5000)
  |> client.default_certificate_authority_file("certs/ca.pem")
}
```

The TLS handshake timeout is a global setting too: `tls_handshake_timeout(ms)`, with a default of 10000ms.

## See also

- [Transport configuration](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/transport-configuration.md): global settings and their defaults
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): timeouts, redirects, and HTTP versions for one request
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle a transport error
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
