# Transport configuration

This guide shows how to configure the gun connection pool and transport for all requests. These settings are global and affect all requests after you apply them.

## Configure the transport

Create a configuration with `transport_config()`, change it with the builder functions, and apply it with `configure_transport()`.

### High-concurrency pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/transport_config_example.gleam#L5-L13"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client

pub fn configure_high_concurrency() -> Nil {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.max_concurrent_streams(500)
  |> client.configure_transport()
}
```

All the transport settings can be set together:

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

## Defaults

| Setting                          | Default | Scope       |
| -------------------------------- | ------- | ----------- |
| `timeout`                        | 30000ms | Per-request |
| `connect_timeout`                | 15000ms | Per-request |
| `auto_redirect`                  | True    | Per-request |
| `max_connections`                | 50      | Global      |
| `idle_timeout`                   | 60000ms | Global      |
| `default_connect_timeout`        | 15000ms | Global      |
| `domain_lookup_timeout`          | 5000ms  | Global      |
| `tls_handshake_timeout`          | 10000ms | Global      |
| `keepalive`                      | 30000ms | Global      |
| `keepalive_tolerance`            | 3       | Global      |
| `max_concurrent_streams`         | 100     | Global      |
| `initial_connection_window_size` | 65535   | Global      |
| `initial_stream_window_size`     | 65535   | Global      |
| `closing_timeout`                | 15000ms | Global      |

Two more global settings have their own guides: `log_level` (default `LogInfo`, see [Logging](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/logging.md)) and `default_certificate_authority_file` (default none, see [TLS and certificate authorities](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md)).

## See also

- [Connection pools](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): how connections are used, and a pool of its own for a caller
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): settings for one request
- [Logging](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/logging.md): set the log level
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
