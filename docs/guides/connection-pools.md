# Controlling connections

Once your program sends more than a request at a time, connections start to matter. Opening one costs a round trip, and a TLS handshake costs more. Open too many and a server, a proxy or your own machine pushes back. Share too few and requests queue behind each other. And one busy part of your program can take every connection to a host, so the rest of it waits. This guide shows how the client shares connections, how HTTP/2 changes that, and how to set limits for the whole program and for one part of it.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which setting to change](#which-setting-to-change)
- [Step 1: See how connections are reused](#step-1-see-how-connections-are-reused)
- [Step 2: Share one connection with HTTP/2](#step-2-share-one-connection-with-http2)
- [Step 3: Limit the connections to a host](#step-3-limit-the-connections-to-a-host)
- [Step 4: Give one caller a pool of its own](#step-4-give-one-caller-a-pool-of-its-own)
- [Step 5: Tune the transport for a busy service](#step-5-tune-the-transport-for-a-busy-service)
- [Step 6: Watch connections in the log](#step-6-watch-connections-in-the-log)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Send requests at the same time and count the connections they use.
- Put many requests on one HTTP/2 connection.
- Cap the connections to each host, and see what a request does while it waits.
- Give a slow, heavy caller its own small pool, so it can't starve the rest of the program.
- Set the transport settings of a busy service in one place.
- Know what the client writes to the log about its connections.

## Before you start

You need the package:

```sh
gleam add dream_http_client
```

The examples run against [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`. Its `/stream/fast` endpoint takes about a second to send its 10 chunks, which is long enough for requests that you send at the same time to overlap. The mock server speaks HTTP/1.1 and HTTP/2 over plain TCP. The [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code) guide shows how to add and start it.

There's nothing to set up before the first request. The client keeps its connection pool in its own OTP application, which Gleam starts with your program.

## Which setting to change

| Your situation | Change | Why |
|:---|:---|:---|
| Many requests at once to one HTTPS API | Nothing, or `protocols(Http2Only)` for a plain-HTTP service | HTTPS negotiates HTTP/2 when the server offers it, and HTTP/2 puts many requests on one connection. |
| A host must never see more than N connections from you | `max_connections(n)` in the transport configuration | It caps the connections to each host for the whole program. Requests over the cap wait. |
| One part of the program sends heavy requests and must not slow the others | `new_pool(max_connections: n)` and `pool(request, it)` | Requests in a pool share only that pool's connections, up to its own limit. |
| Idle connections, keepalive pings, HTTP/2 windows | The transport configuration | See the [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md) for each setting and its default. |

## Step 1: See how connections are reused

To see the pool at work, you need requests that run at the same time. This helper sends each request from its own process and collects the statuses in order:

### Send requests at the same time <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_parallel.gleam#L6-L31"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type ClientRequest, type SendError, send}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result

pub fn send_all(requests: List(ClientRequest)) -> List(Result(Int, SendError)) {
  requests
  |> list.map(start_request)
  |> list.map(await_status)
}

fn start_request(request: ClientRequest) -> Subject(Result(Int, SendError)) {
  let reply_to = process.new_subject()
  process.spawn(fn() {
    let status = send(request) |> result.map(fn(response) { response.status })
    process.send(reply_to, status)
  })
  reply_to
}

fn await_status(
  reply_to: Subject(Result(Int, SendError)),
) -> Result(Int, SendError) {
  // A request ends with its own timeout, so a reply always comes
  process.receive_forever(reply_to)
}
```

Here's how many connections the client has open after each of these, starting from none:

### Connections after each round of requests <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_1.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
send() four times, one after another, to /stream/fast   -> 1 connection
send_all of four requests to /stream/fast                -> [Ok(200), Ok(200), Ok(200), Ok(200)], 4 connections
send_all of the same four requests again                 -> 4 connections
```

The rules behind those numbers:

- An HTTP/1.1 connection carries one request at a time. Four requests at once need four connections.
- When a request ends, its connection goes back to the pool, and the next request to the same host uses it. So the second round opens no new connection.
- The client opens a new connection only when every connection to the host is busy.

Connections are kept per origin: the scheme, the host and the port, and also the protocol setting, the certificate authority file and the pool of the request. Requests that differ in any of these never share a connection.

## Step 2: Share one connection with HTTP/2

HTTP/2 sends many requests over one connection at the same time, each on its own stream. Tell the client to speak HTTP/2 with `protocols`:

### Ask for HTTP/2 over plain HTTP <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_http2.gleam#L5-L11"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type ClientRequest, Http2Only, path, protocols}

pub fn feed_request(api: ClientRequest) -> ClientRequest {
  api
  |> path("/stream/fast")
  |> protocols(Http2Only)
}
```

Four of these at once, with the same `send_all`, give:

### Four HTTP/2 requests at once <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_2.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
[Ok(200), Ok(200), Ok(200), Ok(200)], 1 connection
```

You choose the protocol with one of three values:

- `Http2Preferred`, the default for HTTPS: the client offers HTTP/2 and HTTP/1.1 in the TLS handshake, and the server picks.
- `Http2Only`: HTTP/2 or nothing. Over plain HTTP, this sends HTTP/2 straight away ("prior knowledge"), which is what services inside a cluster often expect.
- `Http1Only`: HTTP/1.1 only.

Plain HTTP uses HTTP/1.1 unless you set `Http2Only`. An HTTP/2 connection carries as many streams at once as the server allows with its `SETTINGS_MAX_CONCURRENT_STREAMS`. When they're all busy, the client opens a second connection.

## Step 3: Limit the connections to a host

By default the client opens up to 50 connections to each host. To change that for the whole program, set `max_connections` in the transport configuration:

### Limit the connections to each host <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_limit.gleam#L5-L11"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{configure_transport, max_connections}

pub fn limit_connections(limit: Int) -> Nil {
  client.transport_config()
  |> max_connections(limit)
  |> configure_transport()
}
```

After `limit_connections(2)`, four requests at once to `/stream/fast` still all succeed, but they share two connections: two run, and two wait until a connection is free.

### Four requests at a limit of two connections <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_3.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
send_all of four requests            -> [Ok(200), Ok(200), Ok(200), Ok(200)], 2 connections
the same with timeout(500) on each   -> two Ok(200), two Error(RequestError(TimedOut(500)))
```

A request waits for a free connection only up to its own timeout. `/stream/fast` takes about a second, so with a 500 ms timeout the two waiting requests give up first. Give requests a timeout that covers the wait when you set a low limit.

## Step 4: Give one caller a pool of its own

A global limit is fair to nobody in particular. Suppose your program calls a reports API that holds each connection for a long time. With the default pool, a burst of report requests takes connection after connection, and short requests to the same host queue behind them.

A pool of its own fixes that. Make it once with `new_pool`, and send the report requests through it with `pool`:

### Give report requests their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_pool.gleam#L5-L21"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type ConnectionPool, new_pool, path, pool,
}

/// Make the pool once, when the program starts, and keep it.
pub fn reports_pool() -> ConnectionPool {
  new_pool(max_connections: 1)
}

pub fn report_request(
  api: ClientRequest,
  reports: ConnectionPool,
) -> ClientRequest {
  api
  |> path("/stream/fast")
  |> pool(reports)
}
```

Three report requests and two ordinary requests to the same host, all at once, give:

### Report requests and ordinary requests at once <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_4.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
[Ok(200), Ok(200), Ok(200), Ok(200), Ok(200)], 3 connections
```

The three report requests share the pool's one connection, one after another. The two ordinary requests don't wait for them: they get two connections of the default pool. A pool's limit applies to the pool alone, and the global `max_connections` doesn't count its connections.

Make the pool once and keep it, for example in your application's state. `client.get_pool(request)` reads the pool back from a request, and `client.get_pool_max_connections(pool)` reads its limit.

## Step 5: Tune the transport for a busy service

`max_connections` is one of the transport settings. They all live in one `TransportConfig`, which you build with `transport_config()` and the setting functions, then apply with `configure_transport()`:

### Configure a busy service <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_tuning.gleam#L5-L17"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type TransportConfig}

pub fn busy_service_config() -> TransportConfig {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.max_concurrent_streams(500)
}

/// Apply it once, when the program starts.
pub fn configure_busy_service() -> Nil {
  client.configure_transport(busy_service_config())
}
```

Getters read a configuration back. For `busy_service_config()`, `get_max_connections` returns `200`, `get_idle_timeout` returns `120000`, and `get_max_concurrent_streams` returns `500`.

`configure_transport` applies the whole configuration, not only the settings you changed. Every setting you didn't set gets its default. So build one configuration with everything you need, and apply it once when your program starts. The [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md) lists every setting and its default.

## Step 6: Watch connections in the log

The client writes a few lines to the OTP logger about its connections and bodies. With the default `log_level`, `LogWarning`, you see only the warnings:

### The warnings of the client <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_6.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1
warning: decompression failed, passing through raw bytes
warning: unrecognized Content-Encoding, passing through raw bytes: br
```

- `connection down` means a connection closed while a request was on it. The test of this guide sends a GET to a server that closes the connection without an answer: the client sends it once more on a new connection, so the log shows two of these lines, one for each connection.
- The two `passing through raw bytes` lines mean the server compressed a body in a way the client can't undo, so you get the bytes as they came.

A server can also close a connection while it is idle. That is normal, and the next request opens a new one, so the default level writes nothing for it. To see a line for each of these closes, set `client.log_level(client.LogInfo)` and apply it with `configure_transport`. Then the same requests give one more line:

### The log lines at LogInfo <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_connections_step_6_info.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
info: [dream_http] connection closed: pid=<pid> protocol=http reason=closed
warning: [dream_http] connection down: pid=<pid> protocol=http reason=closed killed_streams=1
warning: decompression failed, passing through raw bytes
warning: unrecognized Content-Encoding, passing through raw bytes: br
```

The `log_level` setting of the transport configuration picks which of these lines appear. It applies to every line the client writes, and to nothing else in your program:

- `LogDebug` and `LogInfo` show all four lines. The client writes no debug lines.
- `LogWarning`, the default, shows the three warnings, and hides `connection closed`.
- `LogError` and `LogNone` show nothing. The client writes no error lines.

## Test your code

Connection behavior is global: the pool, the transport configuration and the log belong to the whole program. Test it the way the tests of this guide do:

- Run these tests one at a time, after the tests that can run in parallel, because they change state that every request uses.
- Start each test from a known state. The tests here stop and start the `dream_http_client` application, so each starts with no connections and the default configuration.
- Put the configuration back at the end of a test that changes it: `client.configure_transport(client.transport_config())`.

For the code of your program, the more useful test is the one from Step 4: does the heavy caller stay inside its pool? You can see it from the outside. Give every request a 500 ms timeout and send three report requests and two ordinary ones at once. The report requests share one connection, so two of them wait longer than their timeout. The ordinary ones get connections of their own and don't wait. A pool is a value, not global state, so this test can run in parallel with the others. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test that report requests stay in their pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_connections_testing.gleam#L6-L53"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type SendError, RequestError, TimedOut, host, path, port, scheme, timeout,
}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/list
import snippets/guide_connections_parallel.{send_all}
import snippets/guide_connections_pool.{report_request, reports_pool}

pub fn tests() -> TestSuite {
  describe("reports pool", [
    it("holds report requests to one connection", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_998)
      let api = test_api(19_998) |> timeout(500)
      let reports = list.repeat(report_request(api, reports_pool()), 3)
      let ordinary = list.repeat(api |> path("/stream/fast"), 2)

      // Act
      let outcomes = send_all(list.append(reports, ordinary))
      server.stop(mock)

      // Assert
      #(count_timeouts(list.take(outcomes, 3)), list.drop(outcomes, 3))
      |> should
      |> be_equal(#(2, [Ok(200), Ok(200)]))
      |> or_fail_with(
        "Two reports should wait for the pool, the others should not wait",
      )
    }),
  ])
}

fn test_api(mock_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
}

fn count_timeouts(outcomes: List(Result(Int, SendError))) -> Int {
  list.count(outcomes, fn(outcome) {
    outcome == Error(RequestError(TimedOut(500)))
  })
}
```

## Common pitfalls

**Applying only the setting you changed.** *Symptom:* a limit you set earlier is gone. After `limit_connections(2)` and then `transport_config() |> idle_timeout(30_000) |> configure_transport()`, four requests at once open four connections again. *Fix:* `configure_transport` sets every setting. Build the whole configuration in one place, as in [Step 5](#step-5-tune-the-transport-for-a-busy-service).

**A low limit with the default timeout.** *Symptom:* under load, requests wait for their whole timeout and then fail with `TimedOut`, though the server is fast. *Fix:* a request waits for a free connection within its timeout. Raise the limit, give the heavy requests their own pool, or set a timeout that fits the wait you accept.

**A new pool for every request.** *Symptom:* every request opens a new connection, and the pool limit has no effect. *Fix:* requests share connections only with requests of the same pool value. Make the pool once and reuse it.

**Expecting HTTP/2 over plain HTTP by default.** *Symptom:* many parallel requests to an internal HTTP/2 service open many connections. *Fix:* plain HTTP uses HTTP/1.1 unless you set `protocols(Http2Only)`.

## Where to go next

- [Calling a service with a private certificate authority](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md): HTTPS to internal services, where HTTP/2 is negotiated in the TLS handshake.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): what happens when a pooled connection was closed by the server.
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#how-fast-the-client-reads): how a stream holds its connection, and why a long HTTP/1.1 stream closes it.
- [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md): every transport setting and its default.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `new_pool`, `pool`, `protocols`, `transport_config` and `configure_transport`.
