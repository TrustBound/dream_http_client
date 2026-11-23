# Settings reference

Every setting of the client in one place: what it does, how to set it, how to read it back, and its default. The guides explain when you need each one. This page is for looking a setting up.

## Table of Contents

- [Request settings](#request-settings)
- [Stream callbacks](#stream-callbacks)
- [Transport settings](#transport-settings)
- [Protocols](#protocols)
- [Log levels](#log-levels)
- [Recorder settings](#recorder-settings)

## Request settings

Set these on a `ClientRequest` with the builder functions. They apply to that request only. A getter returns `None` for a setting that the request doesn't set, and the request then uses the default in the last column.

| Setting | Set with | Read with | Default |
|:---|:---|:---|:---|
| Method | `method(request, http.Post)` | `get_method` | `http.Get` |
| Scheme | `scheme(request, http.Http)` | `get_scheme` | `http.Https` |
| Host | `host(request, "api.example.com")` | `get_host` | `"localhost"` |
| Port | `port(request, 8080)` | `get_port` | `None`: 80 for HTTP, 443 for HTTPS |
| Path | `path(request, "/users")` | `get_path` | `""` |
| Query | `query(request, "page=2")` | `get_query` | `None` |
| Headers | `headers(request, [Header(..)])`, `add_header(request, name, value)` | `get_headers` | `[]` |
| Body | `body(request, text)`, `body_bits(request, bytes)` | `get_body` | `<<>>` |
| Timeout: the longest wait for the server, in ms | `timeout(request, ms)` | `get_timeout` | `None`: 30000 |
| Connect timeout, in ms | `connect_timeout(request, ms)` | `get_connect_timeout` | `None`: the transport's `default_connect_timeout`, 15000 |
| Follow redirects (at most 5) | `auto_redirect(request, False)` | `get_auto_redirect` | `None`: follow |
| HTTP version | `protocols(request, Http2Only)` | `get_protocols` | `None`: see [Protocols](#protocols) |
| Certificate authority file | `certificate_authority_file(request, path)` | `get_certificate_authority_file` | `None`: the transport's `default_certificate_authority_file`, or the system authorities |
| Connection pool | `pool(request, new_pool(max_connections: n))` | `get_pool`, and `get_pool_max_connections` for its limit | `None`: the shared pool, limited by `max_connections` |
| Recorder | `recorder(request, recorder)` | `get_recorder` | `None` |

Guides: [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md) for the request parts, [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md) for the timeouts and redirects, [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md) for protocols and pools, and [Calling a service with a private certificate authority](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md) for the certificate authority file.

## Stream callbacks

`start_stream` calls these in the stream's own process. Each one is optional.

| Callback | Set with | Called with |
|:---|:---|:---|
| The response headers arrived | `on_stream_start(request, fn(headers))` | `List(Header)` |
| The next part of the body arrived | `on_stream_chunk(request, fn(data))` | `BitArray` |
| The body is complete | `on_stream_end(request, fn(trailers))` | `List(Header)`, the trailing headers, often empty |
| The stream failed | `on_stream_error(request, fn(failure))` | `StreamFailure` |

Guide: [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#step-4-stream-in-the-background-with-callbacks).

## Transport settings

These apply to every request. Build a `TransportConfig` with `transport_config()` and the setting functions, then apply it with `configure_transport(config)`. `configure_transport` sets every setting of the configuration, so a setting you don't set goes back to its default.

| Setting | Set with | Read with | Default |
|:---|:---|:---|:---|
| Connections to each host | `max_connections(config, n)` | `get_max_connections` | 50 |
| Idle time before the pool closes a connection, in ms. A new value applies at once | `idle_timeout(config, ms)` | `get_idle_timeout` | 60000 |
| Connect timeout of a request that sets none, in ms | `default_connect_timeout(config, ms)` | `get_default_connect_timeout` | 15000 |
| DNS lookup timeout, in ms | `domain_lookup_timeout(config, ms)` | `get_domain_lookup_timeout` | 5000 |
| TLS handshake timeout, in ms | `tls_handshake_timeout(config, ms)` | `get_tls_handshake_timeout` | 10000 |
| HTTP/2 ping interval, in ms | `keepalive(config, ms)` | `get_keepalive` | 30000 |
| HTTP/2 pings without an answer before the connection closes | `keepalive_tolerance(config, n)` | `get_keepalive_tolerance` | 3 |
| HTTP/2 `SETTINGS_MAX_CONCURRENT_STREAMS` that the client sends to the server | `max_concurrent_streams(config, n)` | `get_max_concurrent_streams` | 100 |
| HTTP/2 connection flow-control window, in bytes | `initial_connection_window_size(config, bytes)` | `get_initial_connection_window_size` | 65535 |
| HTTP/2 stream flow-control window, in bytes | `initial_stream_window_size(config, bytes)` | `get_initial_stream_window_size` | 65535 |
| Wait for a graceful close, in ms | `closing_timeout(config, ms)` | `get_closing_timeout` | 15000 |
| Certificate authority file of a request that sets none | `default_certificate_authority_file(config, path)` | `get_default_certificate_authority_file` | `None`: the system authorities |
| Log level | `log_level(config, level)` | `get_log_level` | `LogInfo` |

Guide: [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md#step-5-tune-the-transport-for-a-busy-service).

## Protocols

The values of `protocols(request, value)`:

| Value | Over HTTPS | Over plain HTTP |
|:---|:---|:---|
| Not set | Offers HTTP/2 and HTTP/1.1 in the TLS handshake, and the server picks | HTTP/1.1 |
| `Http2Preferred` | Offers HTTP/2 and HTTP/1.1 in the TLS handshake | Asks to upgrade an HTTP/1.1 connection, which few servers support |
| `Http2Only` | Offers only HTTP/2 | HTTP/2 from the first byte ("prior knowledge") |
| `Http1Only` | HTTP/1.1 | HTTP/1.1 |

## Log levels

The values of `log_level(config, value)`. The client writes every line through one module, and the level applies to all of its lines and to no other logging in your program. A new level applies when `configure_transport` returns.

| Value | What the client writes |
|:---|:---|
| `LogDebug` | Every line. The client writes no debug lines, so this is the same as `LogInfo` |
| `LogInfo` (default) | The info line `connection closed`, when a server closes an idle connection, and every warning |
| `LogWarning` | The warnings: a connection that went down with a request on it, a body the client can't decompress, an unknown content encoding, a recorder that doesn't answer, a recording file it can't read correctly, and a recorded stream that failed |
| `LogError` | Nothing. The client writes no error lines |
| `LogNone` | Nothing |

See [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md#step-6-watch-connections-in-the-log).

## Recorder settings

Build a recorder with `recorder.new()` and these functions, then start it with `recorder.start(builder)`.

| Setting | Set with | Default |
|:---|:---|:---|
| Mode | `mode(builder, "record")`, `"playback"` or `"passthrough"` (case-sensitive) | `"passthrough"` |
| Directory of the recording files | `directory(builder, path)` | None. Record and playback mode need one: without it, `start` returns `Error("Recorder directory is required for record/playback")` |
| Match key | `key(builder, matching.request_key(method:, url:, headers:, body:))` | method and URL |
| Request transformer, in every mode | `request_transformer(builder, fn(request))` | no change |
| Response transformer, in record mode only | `response_transformer(builder, fn(request, response))` | no change |

Guides: [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md) and [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md).
