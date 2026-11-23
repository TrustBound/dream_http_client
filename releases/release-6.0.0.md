# dream_http_client v6.0.0

**Release Date:** Unreleased

This release replaces the underlying HTTP backend from Erlang's `httpc` to
[gun](https://github.com/ninenines/gun), enabling native HTTP/2 multiplexing
for high-concurrency workloads. `stream_to()` sends typed stream messages to a
`Subject`, for use in an OTP actor. Per-request settings (`connect_timeout`,
`auto_redirect`, `protocols`, `certificate_authority_file`) are added to the
`ClientRequest` builder. `protocols()` enables h2c (HTTP/2 over cleartext) and
per-request protocol preference. Connection pool settings are managed through a
redesigned `TransportConfig` type with 13 gun-native fields plus `log_level`
for controlling log verbosity. All defaults are production-reasonable.

This release was first prepared as 5.2.0 and never published. It changes four
public types (`SendError.RequestError`, `StreamMessage.StreamError`, the
`on_stream_error` callback, and `stream_yielder` errors) and removes
`StreamMessage.DecodeError`, so it is a major version (5.1.3 → 6.0.0). See
Structured Error Types and Removed below.

dream_http_client now lives in its own repository,
[TrustBound/dream_http_client](https://github.com/TrustBound/dream_http_client).

---

## Structured Error Types

All string-based error representations have been replaced with structured Gleam
types that preserve the full detail gun provides.

### Motivation

String errors (`"econnrefused"`, `"timeout"`, `"HTTP 500 Internal Server Error: ..."`)
hide production issues. Consumers cannot reliably pattern-match on error categories
for retry logic, alerting, or circuit breakers without fragile string parsing.

### New types

**`TransportError`** has 8 variants that preserve all gun error details:
`StreamReset(code, description)`, `Goaway(code, last_stream_id, debug_data)`,
`ConnectionError(code, description)`, `RemoteClosed`, `TimedOut(timeout_ms)`,
`ProcessDown(reason)`, `ConnectFailed(reason)` and `Unexpected(raw)`.

#### Explain a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_transport_error.gleam#L1-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type TransportError, ConnectFailed, StreamReset, TimedOut,
  transport_error_to_string,
}
import gleam/int

pub fn explain(error: TransportError) -> String {
  case error {
    ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    StreamReset(code: code, description: description) ->
      "Stream reset: " <> code <> " - " <> description
    _ -> transport_error_to_string(error)
  }
}
```

**`StreamFailure`** distinguishes HTTP failures from transport errors:
`HttpFailure(response: HttpResponse)` and `TransportFailure(error: TransportError)`.

#### Explain a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_stream_failure.gleam#L1-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamFailure, ConnectFailed, HttpFailure, TransportFailure,
  transport_error_to_string,
}
import gleam/int

pub fn explain_failure(failure: StreamFailure) -> String {
  case failure {
    HttpFailure(response: response) -> "HTTP " <> int.to_string(response.status)
    TransportFailure(error: ConnectFailed(reason: reason)) ->
      "Cannot connect: " <> reason
    TransportFailure(error: error) -> transport_error_to_string(error)
  }
}
```

### Breaking changes

| Before | After |
|--------|-------|
| `RequestError(message: String)` | `RequestError(error: TransportError)` |
| `StreamError(request_id, reason: String)` | `StreamError(request_id, error: StreamFailure)` |
| `on_stream_error(fn(String) -> Nil)` | `on_stream_error(fn(StreamFailure) -> Nil)` |
| `stream_yielder() -> Yielder(Result(BytesTree, String))` | `stream_yielder() -> Yielder(Result(BytesTree, StreamFailure))` |
| `StreamMessage.DecodeError` | Removed |

### Migration guide

**Quick migration.** Before 6.0.0, a failed request gave
`Error(client.RequestError(message: msg))`, where `msg` was a string. Now it
gives `Error(client.RequestError(error: err))`, where `err` is a
`TransportError`. To keep the old string, call
`client.transport_error_to_string(err)`, as the last branch below does:

#### Send a request and describe the result <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_send_error.gleam#L1-L16"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  ConnectFailed, RequestError, ResponseError, transport_error_to_string,
}
import gleam/int

pub fn send_and_describe(request: client.ClientRequest) -> String {
  case client.send(request) {
    Ok(response) -> "Got " <> int.to_string(response.status)
    Error(ResponseError(response: response)) ->
      "HTTP " <> int.to_string(response.status)
    Error(RequestError(error: ConnectFailed(reason: reason))) ->
      "Cannot connect: " <> reason
    Error(RequestError(error: error)) ->
      "Failed: " <> transport_error_to_string(error)
  }
}
```

**Recommended.** Pattern match on the `TransportError` variants for structured
handling, as `explain` in **Explain a transport error** above does.

**Streaming errors.** Before 6.0.0, the `on_stream_error` callback got a
string. Now it gets a `StreamFailure`, which distinguishes HTTP failures from
transport errors:

#### Report a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_error.gleam#L6-L26"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn report_failure(
  reply_to: Subject(String),
) -> Result(client.StreamHandle, String) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/status/500")
  |> client.on_stream_error(fn(failure) {
    case failure {
      client.HttpFailure(response: response) ->
        process.send(reply_to, "HTTP " <> int.to_string(response.status))
      client.TransportFailure(error: error) ->
        process.send(
          reply_to,
          "Transport: " <> client.transport_error_to_string(error),
        )
    }
  })
  |> client.start_stream()
}
```

---

## Feature: Typed stream messages with `stream_to`

`stream_to(request, inbox)` starts a stream that sends typed `StreamMessage`
values to a `Subject(StreamMessage)`: `StreamStart`, a `Chunk` for each part of
the body, then exactly one `StreamEnd` or `StreamError`. It returns the
`RequestId` that each message carries. Use it in an OTP actor: add the inbox to
the actor selector with `process.select`. The stream stops when the process
that called `stream_to()` stops. Record and playback work as with
`start_stream()`.

#### Stream a download into an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L33-L67"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
fn start_download(
  done: Subject(Result(BitArray, String)),
) -> Result(actor.Initialised(State, StreamMessage, Nil), String) {
  let inbox = process.new_subject()
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
  // The actor owns the stream: the stream stops when the actor stops
  use _request_id <- result.map(stream_to(request, inbox))
  let selector = process.new_selector() |> process.select(inbox)
  actor.initialised(State(body: <<>>, done: done))
  |> actor.selecting(selector)
}

fn handle_stream_message(
  state: State,
  message: StreamMessage,
) -> actor.Next(State, StreamMessage) {
  case message {
    StreamStart(..) -> actor.continue(state)
    Chunk(data: data, ..) ->
      actor.continue(State(..state, body: bit_array.append(state.body, data)))
    StreamEnd(..) -> {
      process.send(state.done, Ok(state.body))
      actor.stop()
    }
    StreamError(error: error, ..) -> {
      process.send(state.done, Error(stream_failure_to_string(error)))
      actor.stop()
    }
  }
}
```

`cancel_stream(request_id)` works with the `RequestId` that `stream_to()`
returns. It stops the stream process, cancels the request, and returns after
the stream has stopped, so no message of the stream arrives after it returns. A
cancel of a stream that has ended, or a second cancel of the same stream, does
nothing and returns `Nil`.

#### Cancel a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_cancel_stream.gleam#L6-L17"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn start_then_cancel() -> Result(Nil, String) {
  let inbox = process.new_subject()
  let request =
    client.new()
    |> client.scheme(http.Http)
    |> client.host("localhost")
    |> client.port(9876)
    |> client.path("/stream/fast")
  use request_id <- result.map(client.stream_to(request, inbox))
  // Later: no message of this stream comes after the cancel
  client.cancel_stream(request_id)
}
```

---

## Backend change: httpc → gun

The HTTP client backend has been replaced from Erlang's `httpc` to
[gun](https://github.com/ninenines/gun). This brings:

- **HTTP/2 support** — native multiplexing over a single TCP connection
  when connecting to HTTP/2-capable servers
- **Connection pooling** — managed by a new `dream_http_conn_manager`
  gen_server with per-host multi-connection pools, round-robin selection,
  and automatic dead-connection cleanup
- **Stale connection retry** — requests that hit a server-closed connection
  are automatically retried once on a fresh connection
- **Protocol negotiation** — TLS connections negotiate HTTP/2 via ALPN,
  falling back to HTTP/1.1; plain TCP uses HTTP/1.1

`send()`, `stream_yielder()`, and `start_stream()` keep their behaviour, apart
from the error type changes above.

---

## Feature: Per-request connection timeout

`connect_timeout(ms)` controls how long to wait for the TCP connection to be
established. This is separate from `timeout()`, which controls the entire
request/response cycle.

#### Set a connection timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_connect_timeout.gleam#L5-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn fetch_with_connect_timeout() -> Result(String, client.SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/text")
  |> client.connect_timeout(5000)
  |> client.send()
  |> result.map(fn(response) { response.body })
}
```

**Default:** 15000ms.

**Use case:** Fail fast against unreachable hosts without shortening the
overall request timeout.

---

## Feature: Per-request redirect control

`auto_redirect(enabled)` controls whether 3xx redirects are followed
automatically.

#### Read a redirect status <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_auto_redirect.gleam#L5-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn redirect_status() -> Result(Int, client.SendError) {
  // Disable auto-redirect to inspect the 3xx response
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/redirect/301")
  |> client.auto_redirect(False)
  |> client.send()
  |> result.map(fn(response) { response.status })
}
```

**Default:** `True`.

When disabled, the 3xx response is returned as `Ok(HttpResponse(...))` with
the redirect status code and `Location` header visible. gun does not handle
redirects natively; the shim implements manual redirect following (up to 5
hops).

---

## Feature: Private certificate authorities

`certificate_authority_file(request, path)` makes one request trust only the
certificate authorities in a PEM file, in place of the system ones, the same as
`curl --cacert`. Use it for services with a private certificate authority and
for test servers with their own certificate.
`default_certificate_authority_file(config, path)` sets the same for every
request, through `configure_transport()`. A request's own setting wins.
`get_certificate_authority_file` and `get_default_certificate_authority_file`
read the settings back. Requests that trust different certificate authorities
do not share a pooled connection.

#### Trust a private certificate authority <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam#L4-L10"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn internal_request() -> client.ClientRequest {
  client.new()
  |> client.host("internal.example.com")
  |> client.certificate_authority_file("certs/internal-ca.pem")
  |> client.connect_timeout(2000)
  |> client.auto_redirect(False)
}
```

---

## Feature: Global transport configuration

`TransportConfig` is redesigned with 13 gun-native fields for full
connection pool control.

#### Configure the transport for many requests <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/transport_config_example.gleam#L7-L13"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn configure_high_concurrency() -> Nil {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.max_concurrent_streams(500)
  |> client.configure_transport()
}
```

### Settings

| Builder | Default | What it controls |
|---------|---------|-----------------|
| `max_connections(count)` | 50 | TCP connections per host |
| `idle_timeout(ms)` | 60000 | Idle connection lifetime before close |
| `default_connect_timeout(ms)` | 15000 | TCP connect timeout |
| `domain_lookup_timeout(ms)` | 5000 | DNS resolution timeout |
| `tls_handshake_timeout(ms)` | 10000 | TLS negotiation timeout |
| `retry(count)` | 3 | Connection retry attempts |
| `retry_timeout(ms)` | 1000 | Delay between retries |
| `keepalive(ms)` | 30000 | HTTP/2 PING interval |
| `keepalive_tolerance(count)` | 3 | Missed PINGs before close |
| `max_concurrent_streams(count)` | 100 | HTTP/2 streams per connection |
| `initial_connection_window_size(bytes)` | 65535 | HTTP/2 connection flow control |
| `initial_stream_window_size(bytes)` | 65535 | HTTP/2 stream flow control |
| `closing_timeout(ms)` | 15000 | Graceful shutdown timeout |

### How it works

`configure_transport()` writes the config to a named ETS table
(`dream_http_client_transport_config`). The shim reads from this table
before every connection, falling back to defaults if no config is stored.

The connection pool is managed by `dream_http_conn_manager`, a gen_server
supervised by `dream_http_client_sup`. It uses an ETS `bag` table
(`dream_http_client_connections`) for per-host multi-connection pooling with:

- Round-robin connection selection
- Proactive dead-connection cleanup
- Idle connection reaping
- Crash recovery (re-monitors connections on gen_server restart)

---

## Feature: Per-request protocol preference

Gun supports HTTP/2 over cleartext (h2c) but the connection manager previously
hardcoded HTTP/1.1 for all TCP connections. The new `protocols()` builder on
`ClientRequest` makes protocol preference configurable per-request.

### Usage

h2c uses HTTP/2 over cleartext in "prior knowledge" mode (RFC 7540 Section
3.4):

#### Send an h2c request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/protocols_config.gleam#L6-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn h2c_request() -> Result(HttpResponse, SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/text")
  |> client.protocols(Http2Only)
  |> client.send()
}
```

### Variants

- `Http1Only` — forces HTTP/1.1 (`protocols => [http]`)
- `Http2Only` — forces HTTP/2 (`protocols => [http2]`); enables h2c for TCP, h2-only ALPN for TLS
- `Http2Preferred` — prefers HTTP/2 with fallback (`protocols => [http2, http]`)

### Defaults

When `protocols()` is not called, existing defaults apply: HTTP/2 preferred
(via ALPN) for HTTPS, HTTP/1.1 only for HTTP. No behavior change for
existing code.

### Implementation

ALPN advertisement is automatically aligned with the configured protocol
preference — if you set `Http2Only`, only `h2` is advertised during the TLS
handshake. Connections with different protocol preferences get separate pool
entries to prevent protocol mismatch.

---

## Logging migration: OTP `logger`

Internal logging has been migrated from `error_logger` and raw `io:format` to
OTP's `logger` module. Connection events (graceful closures at `info` level,
unexpected disconnects at `warning` level) and decompression warnings now go
through `logger`, enabling standard OTP log level filtering.

A new `log_level` field on `TransportConfig` controls the minimum severity for
dream_http_client's log output. It uses `logger:set_module_level/2` to scope
filtering to dream's own modules without affecting the rest of your application.

#### Log warnings only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam#L1-L7"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{LogWarning}

pub fn warnings_only() -> Nil {
  client.transport_config()
  |> client.log_level(LogWarning)
  |> client.configure_transport()
}
```

Defaults to `LogInfo`. Available levels: `LogDebug`, `LogInfo`, `LogWarning`,
`LogError`, `LogNone`.

---

## Removed

- `StreamMessage.DecodeError`. A typed message cannot fail to decode, so the
  constructor had no use. Remove the `DecodeError` branch from each `case` on
  a `StreamMessage`.

---

## Fixed

- A streamed response with an empty body now ends at once: `stream_yielder`
  yields nothing and `start_stream` calls `on_stream_end([])`. Before, the
  stream waited until it timed out.
- Transport errors now come back as the `TransportError` docs describe. An
  HTTP/2 stream reset gives `StreamReset(code, description)`, an HTTP/2
  connection error gives `ConnectionError`, a closed connection gives
  `RemoteClosed`, and a killed connection gives `ProcessDown`. Before, most of
  them came back as `Unexpected`. A GOAWAY now gets the one stale-connection
  retry.
- A streamed redirect now works like `send`. A 3xx response with no Location
  returns `HttpFailure` at once instead of waiting until it timed out, and a
  redirect loop returns `Unexpected("Too many redirects (max 5)")` instead of
  streaming the sixth response as a success.
- A stream no longer leaves a process running after the process that started
  it stops, and each stream has one timeout, so no late reply arrives.
- PUT, POST, and PATCH requests no longer hang when sent with an empty body.
  The underlying gun dispatch now uses `gun:request/5` directly instead of
  method-specific functions that behave inconsistently for empty bodies.

---

## Architecture

### Connection lifecycle

```text
request → get_or_open_connection → ensure_connection (gen_server)
  → if below max_connections: gun:open + gun:await_up → new connection
  → if at max: round-robin from pool
  → if stale connection error: close + retry once with new connection
```

### Message routing

- **Sync requests:** `gun:await` / `gun:await_body` in the calling process
- **Pull streaming:** Owner process receives `gun_data` messages directly
- **Message streaming:** Translator process receives gun messages, forwards
  as `{http, ...}` tuples to the stream process

### Auto-redirect

gun does not handle HTTP redirects natively. The shim implements manual
redirect following for all three request paths, supporting up to 5 hops
with proper method/body handling for 301/302/303/307/308.

---

## Test coverage

518 tests, 0 failed, 100% line coverage, in about 170 seconds (with the mock
server and the edge server). Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1,
OTP 29, Gleam 1.19.2.

The tests cover:
- All 13 `TransportConfig` builder/getter round-trips
- Default values, edge cases (zero/one values), builder chaining
- `configure_transport` application
- Concurrent streaming scenarios with connection pool management
- `HttpFailure` carries response headers and body
- `ConnectFailed` variant with descriptive reason
- `transport_error_to_string` and `stream_failure_to_string` helper output
- `stream_to` message order, cancel, and stop with the owner process
- Every tested snippet in the README, the release notes, and the doc comments

---

## Files changed

- `gleam.toml` — Added `gun >= 2.2.0` dependency
- `src/dream_http_client/dream_http_shim.erl` — New file: gun-based FFI shim
  replacing `dream_httpc_shim.erl`
- `src/dream_http_client/dream_http_conn_manager.erl` — New file: connection
  pool gen_server
- `src/dream_http_client/dream_httpc_shim.erl` — Deleted
- `src/dream_http_client/client.gleam` — Structured error types, `stream_to`,
  per-request settings, redesigned `TransportConfig` with 13 gun-native fields
- `src/dream_http_client/internal.gleam` — Updated external function
  references from `dream_httpc_shim` to `dream_http_shim`
- `src/dream_http_client/dream_http_client_app.erl` — Added
  `dream_http_client_connections` ETS table creation
- `src/dream_http_client/dream_http_client_sup.erl` — Added
  `dream_http_conn_manager` as supervised child
- `test/snippets/` — Tested snippets for every code block in the docs
- `CHANGELOG.md` — 6.0.0 entry
- `README.md` — Updated for gun backend and `stream_to`

## Upgrading

Update your dependency:

```toml
[dependencies]
dream_http_client = ">= 6.0.0 and < 7.0.0"
```

Then run:

```bash
gleam deps download
```

Error types have changed (see Structured Error Types above), and
`StreamMessage.DecodeError` is removed. The HTTP backend has been swapped from
`httpc` to `gun`. Use the migration guide above to update error handling code.

## Documentation

- [dream_http_client hexdocs](https://hexdocs.pm/dream_http_client) -- v6.0.0
- [README](https://github.com/TrustBound/dream_http_client/tree/main)
- [CHANGELOG](https://github.com/TrustBound/dream_http_client/blob/main/CHANGELOG.md)

## Community

- [Full Documentation](https://github.com/TrustBound/dream_http_client/tree/main)
- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_http_client/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_http_client/blob/main/CONTRIBUTING.md)

---

**Full Changelog:** [CHANGELOG.md](https://github.com/TrustBound/dream_http_client/blob/main/CHANGELOG.md)
