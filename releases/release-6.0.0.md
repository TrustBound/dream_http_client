# dream_http_client 6.0.0 Release Notes

**Release Date:** not released yet (draft)

This release moves `dream_http_client` from Erlang's `httpc` to [gun](https://github.com/ninenines/gun). Requests to one host now share HTTP/2 connections, and the number of streams on a connection follows what the server allows. Errors are typed values, a response body is bytes, and a stream can send typed messages to an OTP actor.

It is a major version because four public types changed, `StreamMessage.DecodeError` is removed, and `HttpResponse.body` is a `BitArray`. Read the Migration Guide before you upgrade. This release was first prepared as 5.2.0 and never published, so it follows 5.1.3. The package also moved to its own repository.

## Key Highlights

- **gun is the HTTP backend**: HTTP/1.1 and HTTP/2, with connections that requests to one host share
- **Typed errors (breaking)**: `TransportError` and `StreamFailure` take the place of error strings
- **Response bodies are bytes (breaking)**: `HttpResponse.body` is a `BitArray`. Read text with `client.body_text(response)`
- **`stream_to`**: a stream sends typed messages to a `Subject`, for use in an OTP actor
- **A pool of your own**: `client.new_pool(max_connections:)` gives a group of requests its own connections
- **Per-request settings**: `protocols` (with h2c), `connect_timeout`, `auto_redirect` and `certificate_authority_file`
- **Global transport configuration**: `TransportConfig` with 11 gun settings and `log_level`
- **Its own repository**: `dream_http_client` now lives at [TrustBound/dream_http_client](https://github.com/TrustBound/dream_http_client), with its own version and its own releases

## What's New

### The HTTP Backend Is gun

The HTTP client backend has been replaced from Erlang's `httpc` to
[gun](https://github.com/ninenines/gun). This brings:

- **HTTP/2 support**: native multiplexing over a single TCP connection
  when connecting to HTTP/2-capable servers
- **Connection pooling**: managed by a new `dream_http_conn_manager`
  gen_server with per-host multi-connection pools. An HTTP/1.1 connection
  carries one request at a time, an HTTP/2 connection carries as many
  streams as the server allows, and automatic dead-connection cleanup
  removes connections that stopped
- **Stale connection retry**: a request that hits a server-closed
  connection is sent once more on a fresh connection when its method is
  idempotent, or when the server did not process it
- **Protocol negotiation**: TLS connections negotiate HTTP/2 via ALPN,
  falling back to HTTP/1.1; plain TCP uses HTTP/1.1

`send()`, `stream_yielder()`, and `start_stream()` keep their behaviour, apart
from the error type changes in "Structured Error Types" below.

### Structured Error Types

All string-based error representations have been replaced with structured Gleam
types that preserve the full detail gun provides.

#### Motivation

String errors (`"econnrefused"`, `"timeout"`, `"HTTP 500 Internal Server Error: ..."`)
hide production issues. Consumers cannot reliably pattern-match on error categories
for retry logic, alerting, or circuit breakers without fragile string parsing.

#### New types

**`TransportError`** has 9 variants. Eight preserve all gun error details:
`StreamReset(code, description)`, `Goaway(code, description)`,
`ConnectionError(code, description)`, `RemoteClosed`, `TimedOut(timeout_ms)`,
`ProcessDown(reason)`, `ConnectFailed(reason)` and `Unexpected(raw)`. The
ninth, `NoRecording(method, url)`, is a playback request that no recording
matches, which the client does not send.

The `code` of `StreamReset`, `Goaway` and `ConnectionError` is an
`Http2ErrorCode`: one constructor for each HTTP/2 error code of RFC 9113,
for example `RefusedStream`, and `UnknownErrorCode(name)` for any other code.

##### Explain a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_transport_error.gleam#L1-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type TransportError, ConnectFailed, Goaway, NoError, RefusedStream,
  StreamReset, TimedOut, transport_error_to_string,
}
import gleam/int

pub fn explain(error: TransportError) -> String {
  case error {
    ConnectFailed(reason: reason) -> "Cannot reach server: " <> reason
    TimedOut(timeout_ms: ms) -> "Timed out after " <> int.to_string(ms) <> "ms"
    StreamReset(code: RefusedStream, ..) -> "The server refused the request"
    Goaway(code: NoError, ..) -> "The server is going away"
    _ -> transport_error_to_string(error)
  }
}
```

**`StreamFailure`** distinguishes HTTP failures from transport errors:
`HttpFailure(response: HttpResponse)` and `TransportFailure(error: TransportError)`.

##### Explain a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_explain_stream_failure.gleam#L1-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### Typed Stream Messages With `stream_to`

`stream_to(request, inbox)` starts a stream that sends typed `StreamMessage`
values to a `Subject(StreamMessage)`: `StreamStart`, a `Chunk` for each part of
the body, then exactly one `StreamEnd` or `StreamError`. It returns the
`RequestId` that each message carries. Use it in an OTP actor: add the inbox to
the actor selector with `process.select`. The stream stops when the process
that called `stream_to()` stops. Record and playback work as with
`start_stream()`.

##### Stream a download into an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L33-L67"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

##### Cancel a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_cancel_stream.gleam#L6-L17"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### Response Bodies Are Bytes

`HttpResponse.body` is a `BitArray`: the exact bytes the server sent. Before,
it was a `String`, and a body that was not UTF-8 (an image, a PDF, text in
another encoding) was a `String` that was not valid text. On streams, the
body of an error response was read as Latin-1, and its bytes were lost.

`client.body_text(response)` returns `Ok(text)` for a UTF-8 body and
`Error(Nil)` for any other body.

#### Read the body as text <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_body_text.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client

pub fn text_of(response: client.HttpResponse) -> String {
  case client.body_text(response) {
    Ok(text) -> text
    Error(Nil) -> "The body is not text"
  }
}
```

A request body is bytes too. `client.body(String)` sets a text body, as
before. `client.body_bits(BitArray)` sets a body that is not text.

#### Upload a file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_body_bits.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
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
```

### A Connection Pool of Its Own

`client.new_pool(max_connections:)` makes a connection pool. Make it one
time and keep the value. `client.pool(request, pool)` sends a request
through it. Requests share connections only with requests that have the
same pool, and the pool opens at most `max_connections` connections to each
host. When the pool is full, a request waits for room up to its timeout, and
then fails with `TimedOut`. Requests with no pool use the default pool.

#### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client
import gleam/option.{type Option}

pub fn model_pool() -> client.ConnectionPool {
  client.new_pool(max_connections: 3)
}

pub fn model_request(
  pool: client.ConnectionPool,
  prompt: String,
) -> client.ClientRequest {
  client.new()
  |> client.host("api.llm.example")
  |> client.path("/v1/chat")
  |> client.body(prompt)
  |> client.pool(pool)
}

pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
  client.get_pool(request)
  |> option.map(client.get_pool_max_connections)
}
```

### Per-Request Protocol Preference

Gun supports HTTP/2 over cleartext (h2c) but the connection manager previously
hardcoded HTTP/1.1 for all TCP connections. The new `protocols()` builder on
`ClientRequest` makes protocol preference configurable per-request.

#### Usage

h2c uses HTTP/2 over cleartext in "prior knowledge" mode (RFC 7540 Section
3.4):

##### Send an h2c request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/protocols_config.gleam#L6-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

#### Variants

- `Http1Only`: forces HTTP/1.1 (`protocols => [http]`)
- `Http2Only`: forces HTTP/2 (`protocols => [http2]`); enables h2c for TCP, h2-only ALPN for TLS
- `Http2Preferred`: prefers HTTP/2 with fallback (`protocols => [http2, http]`)

#### Defaults

When `protocols()` is not called, existing defaults apply: HTTP/2 preferred
(via ALPN) for HTTPS, HTTP/1.1 only for HTTP. No behavior change for
existing code.

#### Implementation

ALPN advertisement is automatically aligned with the configured protocol
preference: if you set `Http2Only`, only `h2` is advertised during the TLS
handshake. Connections with different protocol preferences get separate pool
entries to prevent protocol mismatch.

### Per-Request Connection Timeout

`connect_timeout(ms)` controls how long to wait for the TCP connection to be
established. This is separate from `timeout()`, which controls the entire
request/response cycle.

##### Set a connection timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_connect_timeout.gleam#L5-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn fetch_with_connect_timeout() -> Result(BitArray, client.SendError) {
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

### Per-Request Redirect Control

`auto_redirect(enabled)` controls whether 3xx redirects are followed
automatically.

##### Read a redirect status <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_auto_redirect.gleam#L5-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### Private Certificate Authorities

`certificate_authority_file(request, path)` makes one request trust only the
certificate authorities in a PEM file, in place of the system ones, the same as
`curl --cacert`. Use it for services with a private certificate authority and
for test servers with their own certificate.
`default_certificate_authority_file(config, path)` sets the same for every
request, through `configure_transport()`. A request's own setting wins.
`get_certificate_authority_file` and `get_default_certificate_authority_file`
read the settings back. Requests that trust different certificate authorities
do not share a pooled connection.

##### Trust a private certificate authority <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_request_settings.gleam#L4-L10"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn internal_request() -> client.ClientRequest {
  client.new()
  |> client.host("internal.example.com")
  |> client.certificate_authority_file("certs/internal-ca.pem")
  |> client.connect_timeout(2000)
  |> client.auto_redirect(False)
}
```

### Global Transport Configuration

`TransportConfig` is redesigned with 11 gun-native fields for full
connection pool control.

##### Configure the transport for many requests <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/transport_config_example.gleam#L7-L13"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn configure_high_concurrency() -> Nil {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.max_concurrent_streams(500)
  |> client.configure_transport()
}
```

#### Settings

| Builder | Default | What it controls |
|---------|---------|-----------------|
| `max_connections(count)` | 50 | TCP connections per host |
| `idle_timeout(ms)` | 60000 | Idle connection lifetime before close |
| `default_connect_timeout(ms)` | 15000 | TCP connect timeout |
| `domain_lookup_timeout(ms)` | 5000 | DNS resolution timeout |
| `tls_handshake_timeout(ms)` | 10000 | TLS negotiation timeout |
| `keepalive(ms)` | 30000 | HTTP/2 PING interval |
| `keepalive_tolerance(count)` | 3 | Missed PINGs before close |
| `max_concurrent_streams(count)` | 100 | HTTP/2 streams per connection |
| `initial_connection_window_size(bytes)` | 65535 | HTTP/2 connection flow control |
| `initial_stream_window_size(bytes)` | 65535 | HTTP/2 stream flow control |
| `closing_timeout(ms)` | 15000 | Graceful shutdown timeout |

#### How it works

`configure_transport()` writes the config to a named ETS table
(`dream_http_client_transport_config`). The shim reads from this table
before every connection, falling back to defaults if no config is stored.

The connection pool is managed by `dream_http_conn_manager`, a gen_server
supervised by `dream_http_client_sup`. It uses an ETS `bag` table
(`dream_http_client_connections`) for per-host multi-connection pooling with:

- Room for each request: one request at a time on an HTTP/1.1 connection,
  and up to the server's `SETTINGS_MAX_CONCURRENT_STREAMS` on an HTTP/2
  connection. The pool waits for the server's first SETTINGS frame before it
  uses a new HTTP/2 connection.
- A new connection only when every connection is full. At
  `max_connections`, a request waits for room up to its timeout.
- One more try on another connection for a refused stream
  (`REFUSED_STREAM` or `too_many_streams`) and after a GOAWAY. Streams that
  the server kept after a GOAWAY finish.
- Proactive dead-connection cleanup
- Idle connection reaping, which never closes a connection that serves a
  response
- Crash recovery (re-monitors connections on gen_server restart)

Streams have flow control. The client reads a streamed response from the
server only as fast as the caller takes chunks from `stream_yielder`, or as
fast as the `on_stream_chunk` callback returns. At most 16 chunks wait in
memory, and the rest of the response waits in the network.

A recorded stream has the status that the server sent, and a stream that
fails is not saved as a recording.

### Logging Uses OTP `logger`

Internal logging has been migrated from `error_logger` and raw `io:format` to
OTP's `logger` module. Connection events (graceful closures at `info` level,
unexpected disconnects at `warning` level), decompression warnings and
recorder warnings go through one module, `dream_http_client_log`.

A new `log_level` field on `TransportConfig` controls the minimum severity for
dream_http_client's log output. It is the `logger:set_module_level/2` level
of that one module, so it applies to every line of the client and does not
change the logging of the rest of your application.

##### Log warnings only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam#L1-L7"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### How It Works

#### Connection lifecycle

```text illustration
request -> ensure_connection (dream_http_conn_manager, a gen_server)
  -> a connection to the host has room: use it
  -> every connection is full, and the pool is below max_connections:
     gun:open, gun:await_up, wait for the server's SETTINGS on HTTP/2
  -> the pool is at max_connections: wait for room, up to the request timeout
  -> no response head, and the server did not process the request (the
     stream was refused, a GOAWAY ended it, or gun never took it): one more
     try on another connection
  -> no response head, the connection closed, and the method is idempotent
     (GET, HEAD, OPTIONS, TRACE, PUT, DELETE): one more try on another
     connection. A POST or PATCH returns the error.
```

#### Message routing

- **Sync requests:** `gun:await` / `gun:await_body` in the calling process
- **Pull streaming:** Owner process receives `gun_data` messages directly
- **Message streaming:** Translator process receives gun messages, forwards
  as `{http, ...}` tuples to the stream process

#### Auto-redirect

gun does not handle HTTP redirects natively. The shim implements manual
redirect following for all three request paths, supporting up to 5 hops
with proper method/body handling for 301/302/303/307/308.

### Its Own Repository

`dream_http_client` moved out of the Dream repository. It has its own version, its own changelog and its own release workflow. The package name on Hex and the module names are the same as before.

### Guides

The package has nine guides in [`docs/guides/`](https://github.com/TrustBound/dream_http_client/tree/main/docs/guides) and one settings reference. Each guide walks through one task, from a first request to tested code: getting started, sending data, errors and retries, streaming, streaming into an actor, connections, private certificate authorities, recording, and matching and scrubbing recordings. Every code block in them is proven: each Gleam block is a tested snippet that runs against a local server, and each output block is a file that a test compares with the real output. The README is short and links to them, and HexDocs shows them.

## Removed

- `StreamMessage.DecodeError`. A typed message cannot fail to decode, so the
  constructor had no use. Remove the `DecodeError` branch from each `case` on
  a `StreamMessage`.

## Bug Fixes

- The connection pool now uses connections the way each protocol expects.
  Before, it opened a new connection for every request until it held 50 for
  a host, then picked one by round robin, so a request could wait behind a
  long stream on the same HTTP/1.1 connection, and HTTP/2 never multiplexed.
  Now:
  - An HTTP/1.1 connection carries one request at a time.
  - An HTTP/2 connection carries as many streams as the server allows with
    `SETTINGS_MAX_CONCURRENT_STREAMS`. The pool waits for the server's first
    SETTINGS frame before it uses a new connection, and follows every later
    one. A server that never sends SETTINGS fails the connect with
    `ConnectFailed("Connection timed out")`.
  - The pool opens a new connection only when every connection to the host
    is full. At `max_connections`, a request waits for room, up to its
    timeout, and then gets `TimedOut`.
  - A stream that the server refuses (`REFUSED_STREAM`, or gun's
    `too_many_streams`) is sent once more on another connection.
  - After a GOAWAY, the connection gets no new request, and the streams that
    the server kept finish. Before, the retry closed the connection and
    stopped them.
- Streams now have flow control. The client reads the response from the
  server only as fast as the caller takes chunks from `stream_yielder`, or
  as fast as the `on_stream_chunk` callback returns. At most 16 chunks wait
  in memory. Before, the client read the whole response as fast as the
  server sent it, so a slow reader of a large response filled memory.
- A stream that nobody reads any more (its caller stopped, or it timed out)
  is now canceled at the server.
- On HTTP/1.1, the connection of a stream of 16 chunks or more is closed
  when the stream ends, because gun can have stopped reading it. A shorter
  stream leaves its connection for the next request. HTTP/2 connections
  are not closed.
- A recorded stream now has the status that the server sent. Before, the
  recorder wrote 206 for a response with `Content-Range` and 200 for every
  other stream.
- A stream that fails is no longer saved as a recording. Before, the chunks
  that arrived were saved, and playback showed them as a whole response.
- A connection in the pool no longer connects again by itself after it
  loses its socket. The pool removes it, and the next request gets a new
  connection. Before, gun connected again after a wait and held new requests
  for that time, and a held request could get response headers and no body,
  and then time out. A request that was sent on a connection that is gone is
  sent once more on a new connection when that is safe (see the RFC 9110 item
  below).
- A 1xx response before the final response, for example 103 Early Hints, no
  longer crashes `send` and the stream functions. The client skips it and
  returns the final response.
- An HTTP/2 GOAWAY now comes back as `Goaway(code, description)`. Before, it
  was `Unexpected("{goaway,no_error,'The connection is going away.'}")`.
  `Goaway` has no `last_stream_id` and no `debug_data`, because gun does not
  give them.
- The idle check no longer closes a connection that serves a long response.
- A stream that stops before its end, for example after a cancel, now closes
  its HTTP/1.1 connection, so the rest of that response never reaches the
  next request. An HTTP/2 connection keeps running.
- A streamed response with an empty body now ends at once: `stream_yielder`
  yields nothing and `start_stream` calls `on_stream_end([])`. Before, the
  stream waited until it timed out.
- Transport errors now come back as the `TransportError` docs describe. An
  HTTP/2 stream reset gives `StreamReset(code, description)`, an HTTP/2
  connection error gives `ConnectionError`, a closed connection gives
  `RemoteClosed`, and a killed connection gives `ProcessDown`. Before, most of
  them came back as `Unexpected`. A stream that a GOAWAY ends was not
  processed, so it gets the one retry on another connection.
- A streamed redirect now works like `send`. A 3xx response with no Location
  returns `HttpFailure` at once instead of waiting until it timed out, and a
  redirect loop returns `Unexpected("Too many redirects (max 5)")` instead of
  streaming the sixth response as a success.
- A stream no longer leaves a process running after the process that started
  it stops, and each stream has one timeout, so no late reply arrives.
- Fixed PUT, POST, and PATCH requests hanging when sent with an empty body.
  The underlying gun dispatch now uses `gun:request/5` directly instead of
  method-specific functions that behave inconsistently for empty bodies.
- A `stream_yielder` that yields an `Error` now ends. Before, it yielded more
  errors on each later pull, and a stream that failed before its first chunk
  sent the request again each time. So `yielder.to_list` never returned. The
  stream also gives its connection back to the pool. In record mode, a stream
  that does not start now yields its real error, not `ProcessDown`.
- Playback of a recorded stream now waits the recorded `delay_ms` before it
  hands over each chunk. Before, all chunks came at once. The request timeout
  limits each wait, as it does live. A cancel, or a `stream_to` owner that
  stops, ends the stream during a wait.
- Playback of a recorded stream with a status outside 2xx now gives one
  `HttpFailure` with the recorded status, headers and body, and no chunks.
  Before, it played back as a successful stream. This applies to
  `stream_yielder`, `start_stream` and `stream_to`, and also to a blocking
  recording that one of them plays back.
- A request whose connection closed before the response head is now sent
  once more only when that is safe. Before, every method was sent again, so
  a server that read a POST and then closed the connection got the POST
  twice. Now the client follows RFC 9110, section 9.2.2, and RFC 9113,
  sections 6.8 and 8.7:
  - A GET, HEAD, OPTIONS, TRACE, PUT or DELETE request is sent once more on
    another connection.
  - A POST, PATCH or other request is sent once, and returns
    `RemoteClosed`, or `ProcessDown("shutdown")` when its connection process
    was stopped.
  - A request that the server did not process is sent once more for every
    method: a stream refused with `REFUSED_STREAM`, a stream above the last
    stream identifier of a GOAWAY, and a request that the connection process
    never took because it stopped after it lost its socket.
  This applies to `send`, `stream_yielder`, `start_stream` and `stream_to`.
- In playback mode, a request that no recording matches is no longer sent
  to the network. Before, it went on to the live service, although the docs
  said that playback uses no network. Now `send` returns
  `Error(RequestError(NoRecording(method: "GET", url: "https://api.example.com/users/42")))`,
  `stream_yielder` yields that error once and ends, `start_stream` calls
  only `on_stream_error`, and `stream_to` sends only `StreamError`. The new
  `TransportError` variant `NoRecording(method, url)` names the request,
  and `transport_error_to_string` gives
  `No recording matches GET https://api.example.com/users/42`. Record mode
  does not change: a request with no recording goes to the network and is
  recorded. `add_recording` still does nothing in playback mode.

- `log_level` now applies to every log line of the client. Before, the
  client logged with `logger:info/2` and `logger:warning/2`, which put no
  module in the log metadata, so the module level that `log_level` set
  never applied: `LogNone` still showed the `connection down` warnings, and
  `LogDebug` did not show the `connection closed` info line. Now every line
  goes through one module, `dream_http_client_log`, with the logger macros,
  and `log_level` is the module level of that module. `LogDebug` and
  `LogInfo` (the default) show the info line and the warnings, `LogWarning`
  shows only the warnings, and `LogError` and `LogNone` show nothing. The
  recorder and recording warnings that the client wrote to standard error
  go through the same module, so `log_level` applies to them too. The
  primary logger level and the logging of other applications do not change.
- A recording is on disk when the recorded call returns. Before, the
  recorder wrote the file after an asynchronous message, so a playback
  recorder started right after `send` could miss it and give
  `NoRecording`, although the docs said that recordings are saved at once.
  Now `send` returns after the write, and a stream ends after the write.
  A failed write is the error of the call:
  `Error(RequestError(Unexpected("Failed to save recording: ...")))` from
  `send`, and a `TransportFailure` with the same `Unexpected` as the last
  item of `stream_yielder` and in `on_stream_error` and `StreamError`.
  Before, a failed write printed a line to standard error and the call
  returned the response. `recorder.add_recording` returns
  `Result(Nil, String)`.
- A new `idle_timeout` applies at once. Before, the idle check that was
  scheduled with the old value (60 seconds by default) ran first, so a
  shorter timeout applied only after it. Now `configure_transport` replaces
  the scheduled check.
- The `connection down` warning is no longer lost when the pool closes a
  connection whose socket the server closed a moment before. gun reports
  the lost socket while it handles the message of the socket, and the pool
  stopped gun with an exit signal, which can take effect first. Now the
  pool stops a connection with a message, after the messages that the
  connection already got.
- The doc of `max_concurrent_streams` says what the value is: the HTTP/2
  `SETTINGS_MAX_CONCURRENT_STREAMS` that the client sends to the server.
  The pool follows the limit that the server sends.

## Testing

740 tests, 0 failed, 100% line coverage (1232 of 1232 lines), in about 150
seconds (with the mock server and the edge server). Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1,
OTP 29, Gleam 1.19.2.

The tests cover:
- All 11 `TransportConfig` builder/getter round-trips
- Default values, edge cases (zero/one values), builder chaining
- `configure_transport` application
- Concurrent streaming scenarios with connection pool management
- `HttpFailure` carries response headers and body
- `ConnectFailed` variant with descriptive reason
- `transport_error_to_string` and `stream_failure_to_string` helper output
- `stream_to` message order, cancel, and stop with the owner process
- Every tested snippet in the README, the release notes, and the doc comments
- Every tested snippet of the guides, each run against a local mock
  server, edge server or TLS server, with the exact output the guide shows
- Which requests the client sends again after a failure, counted at the
  server, for `send`, `stream_yielder`, `start_stream` and `stream_to`
- A playback request with no recording: no request reaches the server

## Upgrading

Update your dependencies:

```toml
[dependencies]
dream_http_client = ">= 6.0.0 and < 7.0.0"
```

Then run:

```bash
gleam deps update dream_http_client
```

### Migration Guide

Step 1 applies to code that handles errors. Step 2 applies to code that reads a response body. Step 3 applies only to code that matches on `StreamMessage`.

#### 1. Error types

| Before | After |
|--------|-------|
| `RequestError(message: String)` | `RequestError(error: TransportError)` |
| `StreamError(request_id, reason: String)` | `StreamError(request_id, error: StreamFailure)` |
| `on_stream_error(fn(String) -> Nil)` | `on_stream_error(fn(StreamFailure) -> Nil)` |
| `stream_yielder() -> Yielder(Result(BytesTree, String))` | `stream_yielder() -> Yielder(Result(BytesTree, StreamFailure))` |
| `StreamMessage.DecodeError` | Removed |
| `HttpResponse.body: String` | `HttpResponse.body: BitArray` (use `client.body_text(response)` for text) |
| `recording.BlockingResponse.body: String` | `recording.BlockingResponse.body: BitArray` |
| `recording.RecordedRequest.body: String` | `recording.RecordedRequest.body: BitArray` |
| `client.get_body() -> String` | `client.get_body() -> BitArray` |
| `recorder.add_recording() -> Nil` | `recorder.add_recording() -> Result(Nil, String)` |

**Quick migration.** Before 6.0.0, a failed request gave
`Error(client.RequestError(message: msg))`, where `msg` was a string. Now it
gives `Error(client.RequestError(error: err))`, where `err` is a
`TransportError`. To keep the old string, call
`client.transport_error_to_string(err)`, as the last branch below does:

##### Send a request and describe the result <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_send_error.gleam#L1-L16"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

**A `case` over every `TransportError` value.** `TransportError` has a new
variant, `NoRecording(method, url)`. A `case` that names every variant and
has no catch-all branch needs one more branch for it.

**Tests that use playback.** A request that no recording matches now fails
with `NoRecording` and is not sent. A test that passed only because such a
request went to the live service now fails. Record that request, or add its
recording to the directory of the recorder.

**Streaming errors.** Before 6.0.0, the `on_stream_error` callback got a
string. Now it gets a `StreamFailure`, which distinguishes HTTP failures from
transport errors:

##### Report a stream failure <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_on_stream_error.gleam#L6-L26"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

#### 2. Response bodies are bytes

`HttpResponse.body` is a `BitArray`. Read text with `client.body_text(response)`, which returns `Error(Nil)` when the body is not UTF-8. `client.get_body(request)` and the recording types also hold bytes. See "Response Bodies Are Bytes" under "What's New".

#### 3. `StreamMessage.DecodeError`

The constructor is removed. Remove the `DecodeError` branch from each `case` on a `StreamMessage`.

## Documentation

- [dream_http_client hexdocs](https://hexdocs.pm/dream_http_client) -- v6.0.0
- [README](https://github.com/TrustBound/dream_http_client/tree/main)
- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md)
- [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md)
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md)
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md)
- [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md)
- [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md)
- [Calling a service with a private certificate authority](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md)
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md)
- [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md)
- [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md)
- [CHANGELOG](https://github.com/TrustBound/dream_http_client/blob/main/CHANGELOG.md)

## Community

- [Full Documentation](https://github.com/TrustBound/dream_http_client/tree/main)
- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_http_client/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_http_client/blob/main/CONTRIBUTING.md)

**Full Changelog:** [CHANGELOG.md](https://github.com/TrustBound/dream_http_client/blob/main/CHANGELOG.md)
