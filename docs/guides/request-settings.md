# Request settings

This guide shows how to set the connection behavior of one request: its timeouts, redirects, and HTTP version. These settings apply only to the request that has them.

## Timeouts and redirects

- `timeout(ms)`: the timeout of the request in milliseconds. The default is 30000ms.
- `connect_timeout(ms)`: the TCP connection timeout in milliseconds. The default is 15000ms.
- `auto_redirect(enabled)`: follow redirects or not. The default is `True`.

### Connect timeout and redirects <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/per_request_settings.gleam#L5-L28"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type HttpResponse, type SendError}
import gleam/http

// Set TCP connection timeout (default: 15000ms)
pub fn fetch_with_connect_timeout() -> Result(HttpResponse, SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/text")
  |> client.connect_timeout(5000)
  |> client.send()
}

// Disable automatic redirect following (default: True)
pub fn fetch_without_redirect() -> Result(HttpResponse, SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/redirect/302")
  |> client.auto_redirect(False)
  |> client.send()
}
```

## HTTP version

`protocols()` sets the protocol preference for the connection. It controls which HTTP protocol version gun negotiates when it opens a connection. When it is not set, the default is HTTP/2 preferred (via ALPN) for HTTPS connections and HTTP/1.1 only for HTTP connections.

- `Http1Only`: HTTP/1.1 only.
- `Http2Only`: HTTP/2 only. For cleartext (TCP) connections, this enables h2c "prior knowledge" mode per RFC 7540 Section 3.4: gun speaks HTTP/2 directly, without an upgrade. For TLS connections, this advertises only `h2` via ALPN.
- `Http2Preferred`: prefer HTTP/2 and fall back to HTTP/1.1. This is the default for TLS connections (ALPN negotiation). For TCP, this uses the HTTP/1.1 Upgrade mechanism, which most servers do not support. Use `Http2Only` for cleartext HTTP/2 instead.

For HTTP/2 over cleartext (h2c), use `Http2Only` with `scheme(http.Http)`:

### Use HTTP/2 only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_http2_only.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{Http2Only}
import gleam/http

pub fn http2_only_request() -> client.ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("internal-service.local")
  |> client.protocols(Http2Only)
}
```

## See also

- [Transport configuration](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/transport-configuration.md): global settings and their defaults
- [TLS and certificate authorities](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md): trust a private certificate authority
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle a timeout and other errors
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
