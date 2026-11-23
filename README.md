<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>Type-safe HTTP client for Gleam with streaming support</b>

</div>

<br />

<div align="center">
  <a href="https://hex.pm/packages/dream_http_client">
    <img src="https://img.shields.io/hexpm/v/dream_http_client" alt="Hex Package">
  </a>
  <a href="https://github.com/TrustBound/dream_http_client/releases">
    <img src="https://img.shields.io/github/v/release/TrustBound/dream_http_client?label=Release" alt="Latest Release">
  </a>
  <a href="https://hexdocs.pm/dream_http_client">
    <img src="https://img.shields.io/badge/hex-docs-lightgreen.svg" alt="HexDocs">
  </a>
  <a href="https://github.com/TrustBound/dream_http_client/actions/workflows/ci.yml?query=branch%3Amain">
    <img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TrustBound/dream_http_client/badges/coverage.json" alt="Coverage">
  </a>
  <a href="https://github.com/TrustBound/dream_http_client/blob/main/LICENSE.md">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License">
  </a>
  <a href="https://gleam.run">
    <img src="https://img.shields.io/badge/gleam-%E2%9C%A8-ffaff3" alt="Gleam">
  </a>
</div>

<br />

# dream_http_client

**Type-safe HTTP client for Gleam with recording + streaming support.**

A standalone HTTP/HTTPS client built on [gun](https://github.com/ninenines/gun), supporting HTTP/1.1 and HTTP/2 with native multiplexing. Provides blocking requests, yielder streaming, and process-based streaming via callbacks. Built with the same quality standards as [Dream](https://github.com/TrustBound/dream), but completely independent—use it in any Gleam project.

---

## Contents

- [Why dream_http_client?](#why-dream_http_client)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Execution Modes](#execution-modes)
- [Recording & Playback](#recording--playback)
- [API Reference](#api-reference)
- [Examples](#examples)

---

## Why dream_http_client?

| Feature                   | What you get                                                |
| ------------------------- | ----------------------------------------------------------- |
| **Three execution modes** | Blocking, yielder streaming, process-based—choose what fits |
| **OTP-first design**      | Process-based streams work great with OTP                   |
| **Recording/playback**    | Record HTTP calls for tests, debug production, work offline |
| **Type-safe**             | `Result` types force error handling—no silent failures      |
| **HTTP/2 ready**          | Native HTTP/2 multiplexing via gun for high concurrency     |
| **Framework-independent** | Zero dependencies on Dream or other frameworks              |
| **Concurrent streams**    | Handle multiple HTTP streams in a single actor              |
| **Stream cancellation**   | Cancel in-flight requests cleanly                           |
| **Builder pattern**       | Consistent, composable request configuration                |

---

## Installation

```bash
gleam add dream_http_client
```

---

## Quick Start

Make a simple HTTP request:

### Simple GET request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_request.gleam#L6-L19"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, host, method, path, port, scheme, send,
}
import gleam/http

pub fn simple_get() -> Result(HttpResponse, SendError) {
  client.new()
  |> method(http.Get)
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> send()
}
```

---

## Execution Modes

dream_http_client provides four execution modes. Choose based on your use case:

### 1. Blocking - `send()`

**Best for:** JSON APIs, small responses

#### Send and handle errors <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_send.gleam#L5-L25"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  HttpResponse, RequestError, ResponseError, host, path, port, scheme, send,
  transport_error_to_string,
}
import gleam/http

pub fn fetch_text() -> Result(String, String) {
  let result =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> send()

  case result {
    Ok(HttpResponse(body: body, ..)) -> Ok(body)
    Error(ResponseError(response: response)) -> Error(response.body)
    Error(RequestError(error: error)) -> Error(transport_error_to_string(error))
  }
}
```

### 2. Yielder Streaming - `stream_yielder()`

**Best for:** AI/LLM streaming, file downloads, sequential processing

#### Count the bytes of a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_yielder_basic.gleam#L5-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/result
import gleam/yielder

pub fn count_stream_bytes() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.try_fold(0, add_chunk_size)
}

fn add_chunk_size(
  total: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use chunk <- result.map(chunk_result)
  total + bytes_tree.byte_size(chunk)
}
```

**⚠️ Note:** This blocks while waiting for chunks. Not suitable for OTP actors handling concurrent operations.

### 3. Process-Based Streaming - `start_stream()`

**Best for:** Background tasks, concurrent operations, cancellable streams

#### Stream with callbacks <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_messages_basic.gleam#L5-L54"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type Header, type StreamFailure, await_stream, host, on_stream_chunk,
  on_stream_end, on_stream_error, on_stream_start, path, port, scheme,
  start_stream, stream_failure_to_string,
}
import gleam/bit_array
import gleam/http
import gleam/io

pub fn stream_and_print() -> Result(Nil, String) {
  let stream_result =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
    |> on_stream_start(print_stream_start)
    |> on_stream_chunk(print_chunk)
    |> on_stream_end(print_stream_end)
    |> on_stream_error(print_stream_error)
    |> start_stream()

  case stream_result {
    Error(reason) -> Error(reason)
    Ok(stream_handle) -> {
      // Wait for the stream to complete
      await_stream(stream_handle)
      Ok(Nil)
    }
  }
}

fn print_stream_start(_headers: List(Header)) -> Nil {
  io.println("Stream started")
}

fn print_chunk(data: BitArray) -> Nil {
  case bit_array.to_string(data) {
    Ok(text) -> io.print(text)
    Error(Nil) -> io.print("<binary>")
  }
}

fn print_stream_end(_headers: List(Header)) -> Nil {
  io.println("\nStream completed")
}

fn print_stream_error(failure: StreamFailure) -> Nil {
  io.println_error("Stream error: " <> stream_failure_to_string(failure))
}
```

### 4. Message-Based Streaming for OTP Actors - `stream_to()`

**Best for:** OTP actors that handle a stream as messages, next to their other messages

`stream_to(request, inbox)` runs the stream in its own process, like
`start_stream()`, and sends typed `StreamMessage` values to `inbox`:
`StreamStart`, a `Chunk` for each part of the body, then exactly one
`StreamEnd` or `StreamError`. Each message carries the `RequestId` that
`stream_to()` returned. Add `inbox` to the selector of your actor with
`process.select`. No untyped message reaches the mailbox of the actor.

The process that calls `stream_to()` owns the stream: when it stops, the
stream stops too. `cancel_stream(request_id)` stops the stream at once, and no
message of the stream arrives after it returns.

#### Stream into an actor <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_to_actor.gleam#L5-L75"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamMessage, Chunk, StreamEnd, StreamError, StreamStart, host, path,
  port, scheme, stream_failure_to_string, stream_to,
}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/otp/actor
import gleam/result

pub type State {
  State(body: BitArray, done: Subject(Result(BitArray, String)))
}

pub fn download_body() -> Result(BitArray, String) {
  let done = process.new_subject()
  use _started <- result.try(
    actor.new_with_initialiser(1000, fn(_self) { start_download(done) })
    |> actor.on_message(handle_stream_message)
    |> actor.start
    |> result.map_error(describe_start_error),
  )
  case process.receive(done, 10_000) {
    Ok(body_result) -> body_result
    Error(Nil) -> Error("The download did not end within 10 seconds")
  }
}

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

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "The download actor did not start in time"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_reason) -> "The download actor stopped while it started"
  }
}
```

**When to use which:**

- Use `start_stream()` when the stream work can run in the stream process:
  callbacks such as `on_stream_chunk` run there, and a `StreamHandle` controls
  the stream. The stream keeps running after the process that started it
  stops.
- Use `stream_to()` when an actor must handle the stream in its own process,
  with its own state, and the stream must stop when the actor stops.

### Choosing a Mode

| Use Case                          | Mode               | Why                                   |
| --------------------------------- | ------------------ | ------------------------------------- |
| JSON API calls                    | `send()`           | Simple, complete response at once     |
| Small file downloads              | `send()`           | Load entire file into memory          |
| AI/LLM streaming (single request) | `stream_yielder()` | Sequential token processing           |
| File downloads                    | `stream_yielder()` | Memory-efficient chunked processing   |
| Background processing             | `start_stream()`   | Non-blocking, concurrent, cancellable |
| Long-lived connections            | `start_stream()`   | Can cancel mid-stream                 |
| Cancellable operations            | `start_stream()`   | Cancel via handle                     |
| Stream handled by an OTP actor    | `stream_to()`      | Typed messages in the actor selector  |

---

## Configuration

### Per-Request Settings

Configure connection behavior on individual requests:

#### Connect timeout and redirects <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/per_request_settings.gleam#L5-L28"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### Transport Settings

Configure the gun connection pool (global, affects all requests):

#### High-concurrency pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/transport_config_example.gleam#L5-L13"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

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

### Defaults

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
| `retry`                          | 3       | Global      |
| `retry_timeout`                  | 1000ms  | Global      |
| `keepalive`                      | 30000ms | Global      |
| `keepalive_tolerance`            | 3       | Global      |
| `max_concurrent_streams`         | 100     | Global      |
| `initial_connection_window_size` | 65535   | Global      |
| `initial_stream_window_size`     | 65535   | Global      |
| `closing_timeout`                | 15000ms | Global      |

---

## Recording & Playback

Record HTTP requests/responses for testing, debugging, and offline development.
All four execution modes fully support both recording and playback:

| Mode               | Record | Playback |
|:-------------------|:------:|:--------:|
| `send()`           | ✓      | ✓        |
| `stream_yielder()` | ✓      | ✓        |
| `start_stream()`   | ✓      | ✓        |
| `stream_to()`      | ✓      | ✓        |

Streaming recordings capture each chunk along with timing information.
The same fixture format is shared between `stream_yielder()`, `start_stream()`
and `stream_to()`, so recordings made with one can be played back by any of them.

### Quick Example <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_basic.gleam#L5-L70"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, host, path, port, recorder as with_recorder,
  scheme, send,
}
import dream_http_client/recorder.{directory, mode, start}
import gleam/http
import gleam/result

pub type RecordingError {
  RecorderFailed(reason: String)
  RequestFailed(error: SendError)
}

// Record real requests
pub fn record_text(
  recordings_directory: String,
) -> Result(HttpResponse, RecordingError) {
  use record_recorder <- result.try(
    recorder.new()
    |> directory(recordings_directory)
    |> mode("record")
    |> start()
    |> result.map_error(RecorderFailed),
  )

  let response =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> with_recorder(record_recorder)
    |> send()
    |> result.map_error(RequestFailed)

  // The recorder writes each recording in its own process. Stop returns
  // when every recording is on disk.
  use Nil <- result.try(
    recorder.stop(record_recorder)
    |> result.map_error(RecorderFailed),
  )
  response
}

// Playback later (no network)
pub fn play_back_text(
  recordings_directory: String,
) -> Result(HttpResponse, RecordingError) {
  use playback_recorder <- result.try(
    recorder.new()
    |> directory(recordings_directory)
    |> mode("playback")
    |> start()
    |> result.map_error(RecorderFailed),
  )

  // Returns the recorded response
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> with_recorder(playback_recorder)
  |> send()
  |> result.map_error(RequestFailed)
}
```

### Recording Modes

- **`"record"`** - Records real requests to disk immediately
- **`"playback"`** - Returns recorded responses (no network)
- **`"passthrough"`** - No recording/playback

**Important:** Recordings are saved immediately when captured. `recorder.stop()` is optional and only performs cleanup. This ensures recordings are never lost even if the process crashes.

### Use Cases

**Testing:**

#### Play back fixtures in tests <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_playback.gleam#L5-L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, host, path, port, recorder as with_recorder,
  scheme, send,
}
import dream_http_client/recorder.{type Recorder, directory, mode, start}
import gleam/http

pub fn start_api_playback() -> Result(Recorder, String) {
  recorder.new()
  |> directory("test/fixtures/api")
  |> mode("playback")
  |> start()
}

// Tests run without external dependencies
pub fn fetch_recorded_text(
  playback_recorder: Recorder,
) -> Result(HttpResponse, SendError) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> with_recorder(playback_recorder)
  |> send()
}
```

**Offline Development:**
Record API responses once, then work offline using recorded responses.

**Debugging Production:**
Record problematic request/response pairs for investigation.

### Request Matching <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/matching_config.gleam#L6-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

// Build a request key function from include/exclude flags
pub fn method_and_url_key() -> matching.MatchKey {
  matching.request_key(
    method: True,
    url: True,
    // Ignore auth tokens, timestamps
    headers: False,
    // Ignore request IDs in body
    body: False,
  )
}

pub fn start_playback(
  recordings_directory: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings_directory)
  |> mode("playback")
  |> key(method_and_url_key())
  |> start()
}
```

### Scrubbing Secrets (Transformers)

If your requests contain secrets (like `Authorization` headers) or volatile fields (timestamps, request IDs),
you can attach a transformer to **normalize** requests _before_ the key is computed and before anything is persisted.

#### Scrub the request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_transformer.gleam#L6-L58"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{
  type Recorder, directory, key, mode, request_transformer, start,
}
import dream_http_client/recording
import gleam/list

pub fn scrub_auth_and_body(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  let recording.RecordedRequest(
    method,
    scheme,
    host,
    port,
    path,
    query,
    headers,
    _body,
  ) = request

  let scrubbed_headers = list.filter(headers, is_not_authorization_header)

  recording.RecordedRequest(
    method: method,
    scheme: scheme,
    host: host,
    port: port,
    path: path,
    query: query,
    headers: scrubbed_headers,
    body: "",
  )
}

fn is_not_authorization_header(header: #(String, String)) -> Bool {
  header.0 != "Authorization"
}

// Requests recorded through this recorder have their secrets scrubbed
pub fn start_scrubbing_recorder(
  recordings_directory: String,
) -> Result(Recorder, String) {
  let request_key_fn =
    matching.request_key(method: True, url: True, headers: True, body: True)

  recorder.new()
  |> directory(recordings_directory)
  |> mode("record")
  |> key(request_key_fn)
  |> request_transformer(scrub_auth_and_body)
  |> start()
}
```

If you need to scrub **responses** (cookies, tokens, PII) before fixtures are written to disk, use a response transformer.
This runs **only in record mode**.

#### Scrub the response <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_response_transformer.gleam#L6-L45"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/recorder.{
  type Recorder, directory, mode, response_transformer, start,
}
import dream_http_client/recording
import gleam/list

pub fn scrub_response(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  case response {
    recording.BlockingResponse(status, headers, _body) ->
      recording.BlockingResponse(
        status: status,
        headers: list.filter(headers, is_not_set_cookie),
        body: "",
      )

    recording.StreamingResponse(status, headers, chunks) ->
      recording.StreamingResponse(
        status: status,
        headers: list.filter(headers, is_not_set_cookie),
        chunks: chunks,
      )
  }
}

fn is_not_set_cookie(header: #(String, String)) -> Bool {
  header.0 != "set-cookie"
}

pub fn start_scrubbing_recorder(
  recordings_directory: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings_directory)
  |> mode("record")
  |> response_transformer(scrub_response)
  |> start()
}
```

### Ambiguous Matches (Key Collisions)

Playback **errors** if more than one recording matches the same request key. This is intentional: it forces you to
refine your key function (or add a transformer) so each request maps to exactly one recording.

#### Playback with a method and URL key <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_ambiguous_match.gleam#L6-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

// A lookup through this recorder returns Error("Ambiguous recording match ...")
// when more than one recording matches the request key
pub fn start_playback(
  recordings_directory: String,
) -> Result(Recorder, String) {
  let request_key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)

  recorder.new()
  |> directory(recordings_directory)
  |> mode("playback")
  |> key(request_key_fn)
  |> start()
}
```

### Recording Storage

Recordings are stored as individual files (one per request) with human-readable filenames:

- Filename format: `{method}_{host}_{path}_{key_hash}_{content_hash}.json`
- **`key_hash`** groups recordings by request key
- **`content_hash`** prevents overwrites when multiple recordings share the same key

```text
mocks/api/GET_localhost__text_a3f5b2_19d0a1.json
mocks/api/POST_localhost__text_c7d8e9_4f22bc.json
```

**Benefits:**

- **O(1) write performance** - No read-modify-write cycles
- **Atomic fixture writes** - Readers never see partial recordings
- **Concurrent tests work** - No file contention between parallel tests
- **Easy inspection** - Each recording is a separate, readable file
- **Version control friendly** - Individual files show clear diffs

---

## API Reference

### Builder Pattern <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/request_builder.gleam#L5-L33"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, add_header, body, host, method, path, port,
  query, scheme, send, timeout,
}
import gleam/http

pub fn send_post() -> Result(HttpResponse, SendError) {
  let json_body = "{\"hello\":\"world\"}"

  client.new()
  // HTTP method
  |> method(http.Post)
  // HTTP or HTTPS
  |> scheme(http.Http)
  // Hostname (required)
  |> host("localhost")
  // Port (optional, defaults 80/443)
  |> port(9876)
  // Request path
  |> path("/post")
  // Query string
  |> query("page=1&limit=10")
  |> add_header("Content-Type", "application/json")
  // Request body
  |> body(json_body)
  // Timeout in ms (default: 30s)
  |> timeout(60_000)
  |> send()
}
```

### Execution

**Blocking:**

- `send(req) -> Result(HttpResponse, SendError)` - Returns complete response (status, headers, body)

**Yielder Streaming:**

- `stream_yielder(req) -> Yielder(Result(BytesTree, StreamFailure))` - Returns yielder producing chunks

**Process-Based Streaming:**

- `start_stream(req) -> Result(StreamHandle, String)` - Starts stream, returns handle
- `await_stream(handle) -> Nil` - Wait for completion (optional)
- `cancel_stream_handle(handle) -> Nil` - Cancel running stream

**Message-Based Streaming:**

- `stream_to(req, inbox) -> Result(RequestId, String)` - Starts stream, sends `StreamMessage` values to `inbox`, returns the request ID
- `cancel_stream(request_id) -> Nil` - Stops the stream; no message of it arrives after this returns

### Types

**`Header`** - HTTP header with `name: String` and `value: String`

**`HttpResponse`** - Complete HTTP response with `status: Int`, `headers: List(Header)`, and `body: String`

**`SendError`** - Error from `send()`:
- `ResponseError(response: HttpResponse)` — HTTP error (4xx/5xx) with full response
- `RequestError(error: TransportError)` — Transport failure (connection, timeout, DNS)

**`StreamHandle`** - Opaque identifier for process-based streams

**`RequestId`** - Opaque identifier of a `stream_to()` stream, carried by each of its messages

**`StreamMessage`** - A message of a `stream_to()` stream:
- `StreamStart(request_id, headers)` — response headers arrived
- `Chunk(request_id, data)` — the next part of the body
- `StreamEnd(request_id, headers)` — the body is complete (`headers` holds the trailing headers)
- `StreamError(request_id, error: StreamFailure)` — the stream failed

### Error Handling

All modes use `Result` types for explicit error handling:

#### Handle each kind of error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/timeout_config.gleam#L5-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  HttpResponse, RequestError, ResponseError, host, path, port, scheme, send,
  timeout, transport_error_to_string,
}
import gleam/http
import gleam/int
import gleam/io

pub fn fetch_text_with_timeout() -> Result(String, String) {
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> timeout(5000)

  case send(request) {
    Ok(HttpResponse(body: body, ..)) -> {
      io.println(body)
      Ok(body)
    }
    Error(ResponseError(response: response)) -> {
      io.println_error("HTTP error " <> int.to_string(response.status))
      Error(response.body)
    }
    Error(RequestError(error: error)) -> {
      let message = transport_error_to_string(error)
      io.println_error("Request failed: " <> message)
      Error(message)
    }
  }
}
```

---

## Examples

All examples are tested and verified. See [test/snippets/](https://github.com/TrustBound/dream_http_client/tree/main/test/snippets) for complete, runnable code.

**Basic requests:**

- [Blocking request](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/blocking_request.gleam) - Simple GET
- [POST with JSON](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/post_json.gleam) - JSON body
- [Request builder](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/request_builder.gleam) - Full configuration
- [Timeout configuration](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/timeout_config.gleam) - Custom timeouts

**Streaming:**

- [Yielder streaming](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_yielder_basic.gleam) - Sequential processing
- [Process-based streaming](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_messages_basic.gleam) - Callback-driven streaming
- [Stream cancellation](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_cancel.gleam) - Cancel via `StreamHandle`

**Recording:**

- [Record and playback](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_basic.gleam) - Testing without network
- [Playback-only testing](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_playback.gleam) - Test fixtures without network
- [Recording with stream_yielder()](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_stream_yielder.gleam) - Record and playback yielder streams
- [Recording with start_stream()](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_start_stream.gleam) - Record and playback callback streams
- [Custom request keys](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/matching_config.gleam) - Configure request matching
- [Request transformers](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_transformer.gleam) - Scrub secrets before keying/persistence
- [Response transformers](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_response_transformer.gleam) - Scrub secrets from recorded responses
- [Ambiguous match errors](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_ambiguous_match.gleam) - Key collision behavior

---

## Design Principles

This module follows [Dream's design principles](https://github.com/TrustBound/dream/blob/release/3.0.0/docs/reference/design-principles.md).

---

## About Dream

This module was originally built for the [Dream](https://github.com/TrustBound/dream) web toolkit, but it's completely standalone and can be used in any Gleam project. It follows Dream's design principles and will be maintained as part of the Dream ecosystem.

## Contributing

See the [Contributing Guide](https://github.com/TrustBound/dream_http_client/blob/main/CONTRIBUTING.md) for guidelines.

---

## License

MIT — see [LICENSE.md](https://github.com/TrustBound/dream_http_client/blob/main/LICENSE.md)

---

<div align="center">
  <sub>Built in Gleam, on the BEAM, by the <a href="https://github.com/trustbound/dream">Dream Team</a> ❤️</sub>
</div>
