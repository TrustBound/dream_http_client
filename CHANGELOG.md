# Changelog

All notable changes to `dream_http_client` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.0.0] - 2026-11-25

This release was first prepared as 5.2.0 and never published. It changes four
public types (`SendError.RequestError`, `StreamMessage.StreamError`, the
`on_stream_error` callback, and `stream_yielder` errors), so it is a major
version.

### Fixed

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
  `Error(RequestError(NoRecording(method: "GET", url: "https://api.example.com/users/42", directory: "test/recordings", nearest: [])))`,
  `stream_yielder` yields that error once and ends, `start_stream` calls
  only `on_stream_error`, and `stream_to` sends only `StreamError`. The new
  `TransportError` variant `NoRecording(method, url, directory, nearest)`
  names the request, the directory that the recorder searched, and up to 3
  recordings with the same method and path, nearest first, with the parts
  that differ. `transport_error_to_string` gives
  `No recording matches GET https://api.example.com/users/42` and then
  either the nearest recordings or
  `No recording in test/recordings has this method and path`. Record mode
  does not change: a request with no recording goes to the network and is
  recorded. `add_recording` still does nothing in playback mode.

- `log_level` now applies to every log line of the client. Before, the
  client logged with `logger:info/2` and `logger:warning/2`, which put no
  module in the log metadata, so the module level that `log_level` set
  never applied: `LogNone` still showed the `connection down` warnings, and
  `LogDebug` did not show the `connection closed` info line. Now every line
  goes through one module, `dream_http_client_log`, with the logger macros,
  and `log_level` is the module level of that module. `LogDebug` and
  `LogInfo` show the info line and the warnings, `LogWarning` (the default)
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

### Added

- A playback miss names the nearest recordings and shows what differs.
  `NoRecording.nearest` holds up to 3 `recorder.NearestRecording(path,
  differences)`: recordings with the same method and path as the request,
  fewest differing parts first, then by path. Each
  `recorder.Difference(part, recorded, requested)` is a part that the key
  compares (`Origin`, `Query`, `Header(name)` or `Body`), compared after
  the request transformer, so a scrubbed value never shows.
  `transport_error_to_string` shows each one with `-` and `+` lines, or
  names the directory when no recording has the method and path.
- `client.new_pool(max_connections:)` makes a connection pool, and
  `client.pool(request, pool)` sends a request through it. Requests share
  connections only with requests that have the same pool, and the pool
  opens at most `max_connections` connections to each host.
  `client.get_pool()` and `client.get_pool_max_connections()` read the
  settings, and `ConnectionPool` is the opaque type of a pool.
- `Http2ErrorCode`, a type for the HTTP/2 error codes of RFC 9113
  (`NoError`, `RefusedStream`, `EnhanceYourCalm` and the others, and
  `UnknownErrorCode(name)` for a code outside them). `StreamReset`, `Goaway`
  and `ConnectionError` carry it in `code`, so a caller matches on a
  constructor, not on text.
- `client.body_text(response)` reads a response body as a UTF-8 string.
- `client.body_bits(request, bytes)` sets a request body that is not text,
  such as a file.

### Changed

- **BREAKING:** A record run replaces the recording of each request that it
  records again. Before, a record run kept the old files: a changed response
  went to a new file next to the old one, and playback then found two
  recordings for one request and failed. Now a record recorder reads the
  recordings in its directory at start. The first recording of a match key
  in the run removes the files that held that key, then writes one file. A
  second response for the key in the same run replaces the first. The files
  of the keys that the run does not record stay. A file that the recorder
  cannot read or decode stops `start` in record mode with
  `Failed to load recordings in record mode: ...`.
- **BREAKING:** A recording file name comes from the request and its match
  key only: `{method}_{host}_{path}_{key_hash}.json`, with the first 16 hex
  characters of the SHA-256 of the key. Before, the name also had a hash of
  the file content, so a stream got a new name in each record run. Playback
  reads every `.json` file of the directory whatever its name, so files with
  the 5.x names still play back. The next record run of such a request
  removes the old file and writes the file with the new name.
- **BREAKING:** `recorder.add_recording` returns `Result(Nil, String)`:
  `Ok(Nil)` when the recording is on disk, or the write error. Before, it
  returned `Nil` before the write.
- **BREAKING:** `HttpResponse.body` is a `BitArray`, the exact bytes the
  server sent. Before, it was a `String` that could hold bytes that are not
  UTF-8. Use `client.body_text(response)` for text. The body of an
  `HttpFailure` of a stream now has the exact bytes too. Before, a body that
  was not UTF-8 was read as Latin-1, and its bytes were lost.
  `stream_failure_to_string` shows such a body as `<11 bytes, not UTF-8>`.
- **BREAKING:** `recording.BlockingResponse.body` and
  `recording.RecordedRequest.body` are `BitArray`. The fixture files do not
  change: a UTF-8 body is stored as text, and any other body as base64.
- **BREAKING:** `client.get_body(request)` returns a `BitArray`. A body set
  with `client.body(String)` is the UTF-8 bytes of its string.
- **BREAKING:** The recorder mode is a typed value, `recorder.Mode`, with
  the constructors `Record`, `Playback` and `Passthrough`. `recorder.mode`
  takes a `Mode`, and `RecorderBuilder.mode` is a `Mode`, so
  `mode("playback")` becomes `mode(recorder.Playback)`. A wrong mode name is
  a compile error, and `start` has no unknown-mode error any more. For a mode
  in a text, for example from an environment variable, use
  `recorder.parse_mode(text)`. It accepts `"record"`, `"playback"` and
  `"passthrough"`, and gives the error that `start` gave before for any
  other text.
- A `MatchKey` with `body: True` has `base64:` and the base64 form of a
  request body that is not UTF-8.
- Moved to its own repository
- `cancel_stream(request_id)` now works with the `RequestId` that
  `stream_to()` returns. It stops the stream process, cancels the request, and
  returns after the stream has stopped, so no message of the stream arrives
  after it returns. A cancel of a stream that has ended, or a second cancel of
  the same stream, does nothing and returns `Nil`.
- Requests that trust different certificate authorities no longer share a
  pooled connection.
- **HTTP backend replaced: `httpc` → `gun`.** The underlying HTTP client has
  been swapped from Erlang's `httpc` to [gun](https://github.com/ninenines/gun),
  a production-grade HTTP/1.1 and HTTP/2 client. This enables native HTTP/2
  multiplexing for high-concurrency workloads (as many concurrent requests
  over one TCP connection as the HTTP/2 server allows). `send()`, `stream_yielder()`,
  and `start_stream()` keep their behaviour, apart from the error type
  changes below.
- **`SendError.RequestError` from `message: String` to `error: TransportError`**
  for structured transport error classification. Pattern match on `TransportError`
  variants for programmatic error handling, or use `transport_error_to_string`
  for the old string behavior.
- **`StreamMessage.StreamError` from `reason: String` to `error: StreamFailure`**
  distinguishing HTTP failures (non-2xx response with headers/body) from
  transport errors (connection drop, timeout, etc.).
- **`on_stream_error` callback from `fn(String) -> Nil` to `fn(StreamFailure) -> Nil`.**
  The callback now receives a `StreamFailure` with full error context instead of
  a formatted string.
- **`stream_yielder` error type from `String` to `StreamFailure`.** Error results
  now carry structured failure information instead of formatted strings.
- **Logging uses OTP `logger` instead of `error_logger`/`io:format`.** Connection
  events, decompression warnings and recorder warnings go through OTP's
  logger. Use `log_level()` on `TransportConfig` to choose which of them
  appear. It defaults to `LogWarning`: a server that closes an idle
  connection writes no line, and a connection that goes down with a request
  on it writes a warning. Set `log_level(LogInfo)` to also see the
  `connection closed` info line.
- The package has nine guides in `docs/guides/`, each one a walk through
  one task from a first request to tested code, and one settings reference.
  Every code block in them is proven: each Gleam block is a tested snippet
  that runs against a local server, and each output block is a file that a
  test compares with the real output. The README is short and links to
  them, and HexDocs shows them.

### Added

- `stream_to(request, inbox)` starts a stream that sends typed
  `StreamMessage` values to a `Subject(StreamMessage)`: `StreamStart`, a
  `Chunk` for each part of the body, then exactly one `StreamEnd` or
  `StreamError`. It returns the `RequestId` that each message carries. Use it
  in an OTP actor: add the inbox to the actor selector with `process.select`.
  The stream stops when the process that called `stream_to()` stops. Record
  and playback work as with `start_stream()`.
- `certificate_authority_file(request, path)` makes one request trust only the
  certificate authorities in a PEM file, in place of the system ones, the same
  as `curl --cacert`. Use it for services with a private certificate authority
  and for test servers with their own certificate.
- `default_certificate_authority_file(config, path)` sets the same for every
  request, through `configure_transport()`. A request's own setting wins.
- `get_certificate_authority_file` and `get_default_certificate_authority_file`.
- **Per-request protocol preference.** `protocols(preference)` controls which
  HTTP protocol version gun negotiates per connection. `Http1Only` forces
  HTTP/1.1, `Http2Only` enables h2c (HTTP/2 over cleartext, RFC 7540
  Section 3.4) for plaintext connections or h2-only for TLS, `Http2Preferred`
  prefers HTTP/2 with HTTP/1.1 fallback. Defaults to HTTP/2 preferred for
  HTTPS (via ALPN) and HTTP/1.1 for HTTP when not set.
- **Per-request TCP connection timeout.** `connect_timeout(ms)` controls how long
  to wait for the TCP connection to be established, separate from the existing
  `timeout()` which controls the entire request/response cycle. Defaults to
  15000ms. Useful for failing fast against unreachable hosts without shortening
  the overall request timeout.
- **Per-request redirect control.** `auto_redirect(enabled)` controls whether
  3xx redirects are followed automatically. When disabled, the 3xx response is
  returned as `Ok(HttpResponse(...))` with the status code and `Location` header
  visible, allowing manual redirect handling. Defaults to `True` (matching
  previous behavior). Note: gun does not handle redirects natively; the shim
  implements manual redirect following (up to 5 hops).
- **Global transport configuration.** `TransportConfig` opaque type with builder
  functions for gun connection pool tuning (11 fields):
  - `max_connections(count)` — TCP connections per host (default: 50)
  - `idle_timeout(ms)` — idle connection lifetime (default: 60000ms)
  - `default_connect_timeout(ms)` — TCP connect timeout (default: 15000ms)
  - `domain_lookup_timeout(ms)` — DNS resolution timeout (default: 5000ms)
  - `tls_handshake_timeout(ms)` — TLS negotiation timeout (default: 10000ms)
  - `keepalive(ms)` — HTTP/2 PING interval (default: 30000ms)
  - `keepalive_tolerance(count)` — missed PINGs before close (default: 3)
  - `max_concurrent_streams(count)` — HTTP/2 streams per connection (default: 100)
  - `initial_connection_window_size(bytes)` — HTTP/2 flow control (default: 65535)
  - `initial_stream_window_size(bytes)` — HTTP/2 stream flow control (default: 65535)
  - `closing_timeout(ms)` — graceful shutdown timeout (default: 15000ms)

  Create with `transport_config()`, configure with builders, apply with
  `configure_transport()`. Settings are global and affect all subsequent
  requests. Stored in ETS for concurrent read access.

- **Connection pool manager.** `dream_http_conn_manager` gen_server manages
  a per-host connection pool backed by an ETS `bag` table. Features round-robin
  selection, automatic dead-connection cleanup, idle connection reaping, and
  crash recovery on restart.
- **Stale connection retry.** An idempotent request (GET, HEAD, OPTIONS,
  TRACE, PUT, DELETE) that hits a server-closed connection
  (`{stream_error, closed}`) is automatically retried once on a fresh
  connection, preventing spurious failures when connection pool entries outlive
  the server-side keep-alive.
- **`TransportError` type (9 variants)** preserving all gun error details:
  `StreamReset`, `Goaway`, `ConnectionError`, `RemoteClosed`, `TimedOut`,
  `ProcessDown`, `ConnectFailed`, `Unexpected`, and `NoRecording` for a
  playback request that no recording matches. Each variant carries the full
  structured information from gun (HTTP/2 error codes, human-readable
  descriptions, GOAWAY fields) instead of flattening to formatted strings.
- **`StreamFailure` type** with `HttpFailure(response: HttpResponse)` and
  `TransportFailure(error: TransportError)`. Distinguishes HTTP-level
  rejections (where response headers like `retry-after` and `x-request-id`
  are available) from transport-level errors (connection drops, timeouts).
- **`transport_error_to_string` and `stream_failure_to_string` helpers** for
  converting structured errors to human-readable log strings.
- **Response headers preserved in non-2xx streaming errors.** When a streaming
  request receives a non-2xx response, the full `HttpResponse` (status, headers,
  body) is now available via `HttpFailure` instead of a formatted string.
- **`gun_down` connection events now logged.** The connection manager logs
  `gun_down` events with connection PID, protocol, reason, and killed/unprocessed
  stream counts via `error_logger:warning_msg`.
- **Getter functions** for all 11 `TransportConfig` fields.
- **24 new tests** covering structured error types, HttpFailure headers/body
  preservation, ConnectFailed variant checks, helper function output, plus
  builder/getter round-trips, default values, edge cases, builder chaining,
  transport application, and concurrent streaming scenarios.

### Removed

- `StreamMessage.DecodeError`. A typed message cannot fail to decode, so the
  constructor had no use.

### Testing

- 781 tests, 0 failed, 100% line coverage (1314 of 1314 lines), in about 154 seconds (with the mock server and the edge server). Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2.

## [5.1.3] - 2026-03-17

### Fixed

- **ETS table ownership no longer causes silent stream process crashes.**
  `dream_http_client` is now a proper OTP application. Both ETS tables
  (`dream_http_client_ref_mapping` and `dream_http_client_stream_recorders`)
  are created in the application's `start/2` callback and owned by the
  application master process, which lives for the entire application lifetime.
  Previously, the tables were owned by whichever short-lived process first
  created them. When that process exited, the tables were destroyed. Concurrent
  stream processes crashed with `badarg` inside
  `decode_stream_message_for_selector/1`, killing the stream silently — no
  `on_stream_error` callback fired.
- **Race condition on ETS table creation eliminated.** Application start is
  serialized by the BEAM's application controller. Two processes can no longer
  race to create the tables.
- **Removed all `try/catch error:badarg` guards from ETS access.** The previous
  fix wrapped every ETS operation in try/catch, which silently swallowed errors
  (e.g., returning compressed bytes as raw data). With the table now guaranteed
  to exist for the application's lifetime, these guards are unnecessary and
  were masking real errors. ETS operations are now direct calls — if the table
  is gone, the process crashes loudly, which is correct behavior.

### Added

- **OTP application infrastructure.** `dream_http_client_app` (application
  behaviour) and `dream_http_client_sup` (supervisor) provide the standard OTP
  lifecycle for the module's ETS tables. This follows the same pattern used by
  Ranch (Cowboy's transport layer).
- **7 regression tests** covering ETS table ownership verification and
  concurrent streaming scenarios. Integration tests verify concurrent streams
  from short-lived callers all complete — the exact scenario from the bug
  report.

### Removed

- **Unsupervised holder process.** The bare `spawn` + `ets:give_away` pattern
  was replaced by proper OTP application ownership.
- **Lazy ETS table creation.** `ensure_ref_mapping_table/0`,
  `ensure_recorder_table/0`, and `ensure_ets_tables/0` are removed. Tables
  exist from application start.

## [5.1.2] - 2026-03-03

### Fixed

- **Query parameters are now included in HTTP requests.** `build_url` in
  `client.gleam` constructed the URL from scheme, host, port, and path but
  never appended the query string. Any caller using `.query("key=value")`
  silently sent requests without query parameters. Affects `send()` and
  `start_stream()`.
- **`stream_yielder()` also dropped query parameters.** `start_httpc_stream`
  in `internal.gleam` had its own URL construction that independently omitted
  the query string — a separate code path from the `build_url` fix above.

### Added

- **8 regression tests** covering query parameter delivery across all three
  execution modes (`send`, `stream_yielder`, `start_stream`), recorder
  integration (record + playback round-trip), URL-encoded special characters,
  and the empty query string edge case. All assertions parse the JSON `query`
  field from the mock server's response for exact matching.

## [5.1.1] - 2026-03-01

### Fixed

- **Stream error reasons are now always decodable as Gleam strings.** Previously,
  transport-level errors from Erlang's `httpc` (e.g., `socket_closed_remotely`,
  `{failed_connect, ...}`) were passed through as raw Erlang atoms/tuples in the
  pull-based streaming path (`stream_yielder`), causing `d.string` decode failures
  and hiding the real error behind "Unknown stream error". Additionally,
  `format_error` could produce non-UTF-8 binaries (Latin-1 from `io_lib:format`),
  which Gleam's string decoder rejected with `DecodeError("String", "String", [])`.
- **All error formatting functions now guarantee valid UTF-8 output.** Added
  `ensure_utf8_binary/1` helper that validates UTF-8, falls back to Latin-1
  reinterpretation for binaries, and uses `~w` (pure ASCII) as a last resort.
  Updated `format_error`, `format_complete_response_error`, `format_exit_reason`,
  `to_binary`, and `ref_to_string` to use it.
- **Pull-based streaming path now formats error reasons.** `stream_owner_wait`
  and `stream_owner_next_message` now call `format_error(Reason)` on httpc error
  reasons instead of passing raw Erlang terms through to the Gleam decoder.
- **Gleam-side decoders have robust fallbacks.** Both `decode_error_reason` in
  `client.gleam` and `receive_next` in `internal.gleam` now use a three-tier
  fallback: try `d.string`, try `d.bit_array` with UTF-8 conversion, fall back
  to `string.inspect`. Error reasons are never silently swallowed.
- **9 new tests** covering transport-level errors (connection refused, connection
  drop mid-stream), non-UTF-8 response bodies, and error string quality across
  all three execution modes (`send`, `start_stream`, `stream_yielder`).

## [5.1.0] - 2026-02-28

### Added

- **Transparent gzip/deflate decompression for all HTTP client modes.** The client now
  automatically sends `Accept-Encoding: gzip, deflate` and decompresses response bodies
  when the server returns `Content-Encoding: gzip` or `Content-Encoding: deflate`.
  This works across all three execution modes:
  - `send()` — synchronous responses are decompressed before returning
  - `start_stream()` — streamed chunks are decompressed on-the-fly via zlib inflate
  - `stream_yielder()` — streamed chunks are decompressed on-the-fly via zlib inflate
- **User-set `Accept-Encoding` headers are preserved.** If you explicitly set an
  `Accept-Encoding` header on a request, the client will not inject its own — your
  header takes precedence.
- **Unrecognized encodings are passed through with a warning.** If a server returns
  an encoding the client does not support (e.g., `br`, `zstd`), the raw bytes are
  passed through unchanged and a warning is logged. The client does not crash.
- **Corrupted compressed data is handled gracefully.** If decompression fails (e.g.,
  corrupted gzip data), the raw bytes are passed through with a warning instead of
  crashing the process.
- **24 new compression tests** covering the full permutation matrix of encoding type
  (gzip, deflate, identity, none, unknown, corrupted) x request mode (send, start_stream,
  stream_yielder), header injection behavior, and zlib lifecycle cleanup.
- **10 new streaming regression tests** for the non-streaming response bug fix (see Fixed below).

### Fixed

- **Streaming requests no longer crash when upstream returns a non-streaming error response.**
  When a streaming HTTP request (`start_stream()` / `stream_yielder()`) hit an endpoint that
  returned a complete HTTP error (e.g., 401, 403, 429, 500 with a JSON body) instead of starting
  an SSE stream, Erlang's `httpc` sent a complete response message that was unhandled.
  `decode_stream_message_for_selector` crashed with `error(badarg)`, killing the stream process
  and causing a 504 timeout. The `on_stream_error` callback was never invoked, and the upstream
  error details (status code, response body) were lost entirely.
- **All four streaming code paths now handle complete response messages:**
  - `decode_stream_message_for_selector/1` — was crashing with `error(badarg)`, now routes to `stream_error`
  - `receive_stream_message/1` — was timing out silently, now returns `stream_error` with status and body
  - `stream_owner_wait/5` — was silently discarding the message via `_Other` catchall, now buffers the error
  - `stream_owner_next_message/2` — was recursing forever via `_Other` catchall, now returns the error
- **Error messages include HTTP status code and response body.** The `on_stream_error` callback
  (and `stream_yielder` `Error` results) now receive a formatted message like
  `"HTTP 401 Unauthorized: {\"error\":{\"message\":\"Invalid API key\"}}"` instead of crashing
  or timing out.

## [5.0.0] - 2026-02-16

### Breaking Changes

- **`send()` now returns `Result(HttpResponse, SendError)`** instead of `Result(String, String)`.
  - `HttpResponse` carries `status: Int`, `headers: List(Header)`, and `body: String`.
  - `SendError` has two variants:
    - `ResponseError(response: HttpResponse)` — server returned 4xx/5xx (full response available)
    - `RequestError(message: String)` — connection failure, timeout, DNS error, or recorder error
  - HTTP error responses (status >= 400) are now routed to `Error(ResponseError(...))` instead of `Ok(body)`.
  - Successful responses (status < 400) are `Ok(HttpResponse(...))`.

### Fixed

- **HTTP 4xx/5xx responses no longer silently succeed.** In 4.x, a 404 or 500 response
  came back as `Ok(body)`, identical to a 200. Callers had no way to detect failure without
  parsing the body. Now 4xx/5xx responses are routed to `Error(ResponseError(response))`
  with the full `HttpResponse` available for inspection — status code, headers, and body.
- **`start_stream()` playback no longer errors.** In 4.x, `start_stream()` with a recorder
  in playback mode returned `Error("Message-based streaming does not support playback mode")`.
  Callback-based streaming could record but never play back, forcing tests to hit real endpoints
  every run. Now `start_stream()` replays recorded chunks directly via your callbacks.
- **`dream_opensearch` adapted to `client.new()`.** The opensearch client was still using the
  pre-4.0 `client.new` (without parentheses), which worked by accident in 4.x but was
  technically incorrect per the 4.0 migration guide.

### Added

- **`HttpResponse` type** — carries `status: Int`, `headers: List(Header)`, and `body: String`
  for complete HTTP response inspection.
- **`SendError` type** — typed error variants distinguishing HTTP errors (`ResponseError`) from
  transport failures (`RequestError`), replacing opaque `Error(String)`.
- **`start_stream()` playback support.** When a recorder is attached and a matching recording
  exists, `start_stream()` replays recorded chunks directly via your `on_stream_start`,
  `on_stream_chunk`, and `on_stream_end` callbacks — no network calls required. All three
  execution modes (`send()`, `stream_yielder()`, `start_stream()`) now fully support both
  recording and playback.

### Migration Guide

**Before (4.x):**

```gleam
case client.send(request) {
  Ok(body) -> use_body(body)
  Error(message) -> handle_error(message)
}
```

**After (5.0):**

```gleam
case client.send(request) {
  Ok(client.HttpResponse(status: status, headers: headers, body: body)) ->
    use_response(status, headers, body)
  Error(client.ResponseError(response: client.HttpResponse(body: body, ..))) ->
    handle_http_error(body)
  Error(client.RequestError(message: message)) ->
    handle_connection_error(message)
}
```

**Quick migration** — if you only need the body:

```gleam
let assert Ok(client.HttpResponse(body: body, ..)) = client.send(request)
```

## [4.1.0] - 2026-01-28

### Changed

- Recording fixtures are written atomically to prevent partial reads during capture.

### Added

- Storage test coverage for atomic fixture writes and cleanup.

## [4.0.0] - 2025-12-29

### Breaking Changes

- **Recorder API redesigned**: `recorder.start(mode, matching_config)` replaced by a builder API:
  - `recorder.new() |> directory(dir) |> mode("record"|"playback"|"passthrough") |> start()` (import `dream_http_client/recorder.{directory, mode, start}`)
- **Client request builder updated**:
  - `client.new` is now `client.new()` (function) for consistency with other builders
- **Matching API redesigned**:
  - Removed `matching.MatchingConfig`, `matching.match_url_only()`, and signature/match helpers
  - Added `matching.MatchKey` and `matching.request_key(method:, url:, headers:, body:)`
- **Ambiguous playback now errors**: if multiple recordings share the same computed key, lookup returns an error (indicates the key/transformer is too coarse).
- `recorder.find_recording(...)` now returns `Result(Option(Recording), String)` to surface ambiguity errors.

### Added

- **Custom match keys** via `recorder.key(...)` (any `RecordedRequest -> String`).
- **Request transformer hook** via `recorder.request_transformer(...)` to normalize/scrub requests before keying and persistence.
- **Response transformer hook** via `recorder.response_transformer(...)` to scrub recorded responses before they are written to disk (Record mode only).

### Changed

- Recording filenames now include both a **key hash** and a **content hash** to avoid overwriting when multiple recordings share a key:
  - `{method}_{host}_{path}_{key_hash}_{content_hash}.json`
- Recorded responses now persist more metadata for safer fixtures:
  - **Blocking** recordings persist the response **status code** and **headers**
  - **Streaming** recordings persist response **headers** captured from `stream_start` (and trailing headers when available)

## [3.0.1] - 2025-12-10

### Added

- **Per-File Recording Strategy** - Recordings now stored in individual files with format `{method}_{host}_{path}_{hash}.json`
- Human-readable filenames with hash suffix for uniqueness
- O(1) write performance (no more read-modify-write cycles)
- Concurrent test recording support (no file contention)
- `gleam_crypto` dependency for generating unique filename hashes

### Changed

- **Internal:** `storage.save_recordings()` and `storage.save_recording_immediately()` now require a `matching_config` parameter (not user-facing - users interact with `recorder` module)
- Recordings are now organized as individual files instead of a single `recordings.json`
- Better organization for large test suites - each recording is version controllable

### Fixed

- Eliminated O(n) read-modify-write performance issue
- Concurrent tests can now record safely without file contention

**Note:** Backward compatible - existing recordings still load correctly. User-facing `recorder` API unchanged.

## [3.0.0] - 2025-12-09

### Breaking Changes

**Redesigned Streaming API**

- Removed `stream_messages()` - replaced with `start_stream()` using callback-based API
- Removed `select_stream_messages()` - no longer needed with new design
- Streaming now uses dedicated processes with callbacks instead of selector boilerplate
- `StreamMessage`, `RequestId` types still exist but are internal implementation details

**New Streaming Functions:**

- `start_stream(request) -> Result(StreamHandle, String)` - Spawn stream with callbacks
- `await_stream(handle)` - Wait for stream completion
- `cancel_stream_handle(handle)` - Cancel running stream
- `is_stream_active(handle)` - Check if stream still running

**Builder Functions for Callbacks:**

- `on_stream_start(callback)` - Called when stream starts (optional)
- `on_stream_chunk(callback)` - Called for each chunk (optional)
- `on_stream_end(callback)` - Called when stream completes (optional)
- `on_stream_error(callback)` - Called on error (optional)

**Header Type Added**

- Introduced `Header` type for type-safe header handling
- `Header(name: String, value: String)` replaces raw tuples throughout
- `get_headers()` now returns `List(Header)` instead of `List(#(String, String))`
- `StreamStart` and `StreamEnd` use `List(Header)` for headers
- `add_header(name, value)` still takes strings (builds Header internally)

### Changed

**Recordings Now Saved Immediately**

- Recordings are now saved to disk immediately when captured, rather than waiting for `stop()` to be called
- `recorder.stop()` is now optional - it only performs cleanup of the recorder process
- This ensures recordings are never lost even if the process crashes or `stop()` is not called
- Added `storage.save_recording_immediately()` function for immediate persistence

**Performance Tradeoff:** Immediate saving uses a read-modify-write approach (O(n) where n is existing recordings), prioritizing reliability over performance. This is suitable for typical use cases (record once, playback often). If you need high-performance recording, please create an issue at https://github.com/TrustBound/dream/issues.

### Documentation

- Added comprehensive hexdocs for all public functions and types across all modules
- Enhanced Erlang FFI documentation with detailed parameter and return value descriptions
- Improved examples and usage notes throughout the codebase
- Added tested code snippets following dream_ets pattern

### Migration Guide

**From 2.x stream_messages() to 3.0 start_stream():**

Before (2.x):

```gleam
let selector = process.new_selector()
  |> client.select_stream_messages(HttpStream)

let assert Ok(req_id) = client.stream_messages(request)

// Manual selector receive loop...
```

After (3.0):

```gleam
let assert Ok(stream) = client.new()
  |> client.on_stream_chunk(fn(data) { process_chunk(data) })
  |> client.start_stream()

client.await_stream(stream)  // Optional
```

**Header type:**

Before (2.x):

```gleam
let headers: List(#(String, String)) = client.get_headers(req)
```

After (3.0):

```gleam
let headers: List(Header) = client.get_headers(req)
// Access with header.name and header.value
```

## [2.1.1] - 2025-11-29

### Fixed

**Critical: Streaming Recording Now Actually Works**

- Fixed broken streaming recording in `stream_yielder()` - was only doing playback, not recording
- Fixed missing recorder integration in `stream_messages()` - had no recording implementation at all
- Fixed `RequestId` type safety by eliminating `Dynamic` type leak - now wraps `String` properly
- Fixed ETS-based bidirectional mapping for stream cancellation in recorded streams
- Streaming recording now captures chunks and timing delays as they arrive, not just on completion

**Error Handling and Code Quality**

- Eliminated all error discarding with underscore patterns (`Error(_)`, `Error(_error)`) throughout the module
- Added explicit error logging with `io.println_error()` to surface previously-silent failures
- Flattened deeply nested case expressions into named helper functions for maintainability
- Improved error messages and documentation for debugging

**Documentation**

- Added comprehensive documentation for `encode_recording_file()` and `decode_recording_file()`
- Updated `ClientRequest` module docs to reference current public API entrypoints
- Clarified expected error logging in tests (connection failures and timeouts are intentional)

### Changed

- Recording storage moved from `/tmp` to `build/` directory (cleaned by `gleam clean`)
- Added `dream_ets` dependency to project for ETS state management
- Internal variables renamed for clarity throughout (e.g., `req` → `client_request`, `rec` → `recorder_instance`)

### Technical Notes

- The streaming recording implementation was fundamentally broken in 2.1.0 - tests were rigged by manually creating `Recording` objects instead of making real HTTP requests
- Users who tried to record streaming requests in 2.1.0 got empty recordings
- This release actually implements what 2.1.0 claimed to provide
- `RequestId` strings are generated from httpc refs (e.g., `#Ref<0.123.456>`) - unique per VM but not stable across restarts
- Recording only adds overhead when recorder is attached in Record mode - zero cost otherwise
- ETS tables (`dream_http_client_stream_recorders`, `dream_http_client_ref_mapping`) are created on-demand

## [2.1.0] - 2025-11-28

### Added

**HTTP Request/Response Recording and Playback**

- Added recording and playback capabilities for HTTP requests and responses
- Added `recorder` module with `Record`, `Playback`, and `Passthrough` modes
- Added `matching` module for customizable request matching strategies
- Added `recording` module with `RecordedRequest`, `RecordedResponse`, and `Recording` types
- Added `storage` module for persisting and loading recordings from JSON files
- Supports both blocking and streaming requests
- Recordings preserve chunk timing for realistic streaming playback
- Added `client.recorder()` builder function to attach recorders to requests

**Request Inspection (Getter Functions)**

- Made `ClientRequest` type opaque to ensure API stability
- Added getter functions for all request properties:
  - `get_method()` - Get the HTTP method
  - `get_scheme()` - Get the URI scheme (HTTP/HTTPS)
  - `get_host()` - Get the hostname
  - `get_port()` - Get the optional port number
  - `get_path()` - Get the request path
  - `get_query()` - Get the optional query string
  - `get_headers()` - Get the headers list
  - `get_body()` - Get the request body
  - `get_timeout()` - Get the optional timeout
  - `get_recorder()` - Get the optional recorder
- Enables request inspection for logging, testing, and middleware

### Changed

- **Breaking (for direct constructor usage only)**: `ClientRequest` type is now opaque
  - The constructor can no longer be used directly for pattern matching
- Use builder pattern (`client.new()` + setters) and getter functions instead
  - This change only affects code that was directly constructing or pattern matching `ClientRequest`
  - The builder pattern (documented public API) remains unchanged and non-breaking

### Technical Notes

- Added dependencies: `gleam_json`, `simplifile`, `gleam_otp` for recording functionality
- Internal function `get_timeout` renamed to `resolve_timeout` to avoid naming conflict with public getter

## [2.0.0] - 2025-11-24

### 🚨 Breaking Changes

**Module Consolidation**

- **BREAKING**: Consolidated `fetch` and `stream` modules into unified `client` module
  - Migration: Change `import dream_http_client/fetch` to `import dream_http_client/client`
  - Migration: Change `fetch.request()` to `client.send()`
  - Migration: Change `import dream_http_client/stream` to `import dream_http_client/client`
  - Migration: Change `stream.stream_request()` to `client.stream_yielder()`

**Stream Yielder API Change**

- **BREAKING**: `stream_yielder()` now returns `yielder.Yielder(Result(BytesTree, String))` instead of `yielder.Yielder(BytesTree)`
  - Migration: Wrap chunk processing in `case` to handle `Ok(chunk)` and `Error(reason)`
  - Reason: Errors were being silently discarded; now properly surfaced to callers

**StreamMessage Type Change**

- **BREAKING**: Added `DecodeError(reason: String)` variant to `StreamMessage` type
  - Migration: Update pattern matches to handle `DecodeError` or use catch-all pattern
  - Reason: FFI corruption now returns explicit error instead of faking RequestId

### Added

**Message-Based Streaming**

- Added `stream_messages()` for OTP actor integration
- Added `StreamMessage` type with `StreamStart`, `Chunk`, `StreamEnd`, `StreamError`, and `DecodeError` variants
- Added `RequestId` opaque type for stream identification in concurrent scenarios
- Added `select_stream_messages()` for OTP selector integration
- Added `cancel_stream()` for graceful stream cancellation

**Configuration**

- Added configurable request timeout via `client.timeout(request, milliseconds)` builder
- Default timeout is 600 seconds (10 minutes) if not specified
- Added `MOCK_SERVER_PORT` environment variable for configurable test port

**Testing**

- All tests now use `dream_mock_server` instead of external dependencies like httpbin.org
- Added comprehensive error handling tests
- Added unit tests for malformed header handling
- Added unit test for `timeout()` builder function
- Added regression tests for `stream_yielder` completion behavior

### Changed

**Error Handling**

- All errors now include underlying decode errors instead of being discarded
- Improved error messages to be actionable and user-friendly
- Removed all `panic` calls in favor of graceful error returns
- All timeout values now configurable (previously hardcoded 600 seconds)

**FFI Boundary**

- Refactored FFI boundary: Erlang now handles all raw `httpc` message parsing and normalization
- Gleam client receives clean, simplified data structures from FFI
- Better separation of concerns between Erlang (raw parsing) and Gleam (type-safe API)

**Code Quality**

- Eliminated all anonymous functions and closures (coding standards compliance)
- Flattened all nested `case` expressions (coding standards compliance)
- Comprehensive error handling throughout codebase
- No more error discarding with `Error(_)` or `let _ = error` patterns

### Fixed

- Fixed `send()` hanging on non-chunked responses by implementing separate synchronous `httpc` mode
- Fixed `stream_yielder()` incorrectly signaling errors for normal stream completion
- Fixed `stream_yielder()` and `stream_messages()` to correctly include port in URLs
- Fixed message routing in streaming mode to send to correct process
- Fixed `decode_headers()` error handling to propagate failures instead of hiding them
- Fixed `RequestId` handling during FFI corruption (now returns `DecodeError` variant)
- Fixed streaming tests not filtering messages by `RequestId`, causing cross-contamination

### Acknowledgements

Special thanks to **Louis Pilfold** for bringing to our attention that the HTTP client did not support message-based streaming for OTP actors, which led to the comprehensive overhaul in this release.

## [1.0.2] - 2025-11-21

### Changed

- Added HexDocs documentation badge to README

## [1.0.1] - 2025-11-22

### Fixed

- Fixed logo display on hex.pm by using full GitHub URL
- Added Dream logo to README

## [1.0.0] - 2025-11-21

### Added

- Initial stable release
- Builder pattern for HTTP request configuration
- `fetch.request()` - Non-streaming HTTP requests
- `stream.stream_request()` - Streaming HTTP requests with yielder
- Support for all HTTP methods (GET, POST, PUT, DELETE, etc.)
- HTTPS support via Erlang's httpc
- Header management (add, replace)
- Query string support
- Request body support
