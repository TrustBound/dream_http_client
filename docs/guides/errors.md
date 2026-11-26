# Handling errors, timeouts and retries

A request can fail in more ways than "it didn't work". The server can say no. It can be busy and say "try later". It can be unreachable, or too slow, or it can close the connection halfway through. Each of these calls for something different: give up, wait and try again, or tell a person. This guide shows you how to tell them apart, how to set the timeouts and redirects that decide some of them, and how to retry without sending the same order twice.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [What can go wrong](#what-can-go-wrong)
- [Step 1: Sort a result into what to do next](#step-1-sort-a-result-into-what-to-do-next)
- [Step 2: Set the timeouts](#step-2-set-the-timeouts)
- [Step 3: Decide about redirects](#step-3-decide-about-redirects)
- [Step 4: Retry what is safe to retry](#step-4-retry-what-is-safe-to-retry)
- [When the client sends a request again](#when-the-client-sends-a-request-again)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Turn any result of `send()` into one of three outcomes: done, try later, or give up.
- Give a slow endpoint the time it needs, and no more.
- Follow redirects, or stop and read where they point.
- Retry a failed request with a growing wait, but only when the method is safe to repeat.
- Know exactly when the client already sent a request a second time for you.

## Before you start

You need the package:

```sh
gleam add dream_http_client
```

The examples run against [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`. Its `/status/<code>` endpoint answers with any status you ask for, `/slow` answers after 5 seconds, and `/redirect/302` redirects to `/text`. The [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code) guide shows how to add and start it. As in the other guides, `api` is a base request with the scheme, host and port of the mock server.

## What can go wrong

`send()` returns `Result(HttpResponse, SendError)`, and `SendError` has two cases:

- `ResponseError(response)`: the server answered with a status of 400 or more. You get the whole response, with its headers and body.
- `RequestError(error)`: the request got no usable answer. `error` is a `TransportError`.

Here's what each `TransportError` means, and what usually helps:

| Error | What happened | Usually |
|:---|:---|:---|
| `ConnectFailed(reason)` | No connection: nothing listens on the port (`"Connection refused"`), the host name doesn't resolve, or the TLS handshake failed | Try later, or fix the address |
| `TimedOut(timeout_ms)` | The server sent nothing for `timeout_ms` while the client waited | Try later, or raise the timeout |
| `RemoteClosed` | The server closed the connection before the response was complete | Try later, if the method is safe to repeat |
| `ProcessDown(reason)` | The process that held the connection stopped | Try later, if the method is safe to repeat |
| `StreamReset(code, description)` | An HTTP/2 server reset the stream. `RefusedStream` means it didn't process the request | Depends on `code` |
| `Goaway(code, description)` | An HTTP/2 server is shutting the connection down | Try later |
| `ConnectionError(code, description)` | The HTTP/2 connection broke a protocol rule | Give up and report it |
| `NoRecording(method, url, directory, nearest)` | A recorder in playback mode has no recording for this request, so the client didn't send it. `nearest` names up to 3 recordings with the same method and path, and the parts that differ | Record the request, or fix the part that differs. See [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md) |
| `Unexpected(raw)` | Anything else, for example a redirect loop or a URL that isn't valid | Give up and report it |

`transport_error_to_string(error)` turns any of them into one line for a log. The streaming functions report the same `TransportError` inside a `StreamFailure`. The [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#step-3-handle-a-stream-that-fails) guide covers that side.

### The shared error type

`client.to_error(error)` maps a `TransportError` to `dream_errors.Error(TransportError)`, the error type that the Dream packages share. An app that also uses other Dream packages can then handle all their errors with one type. The `TransportError` stays whole as the cause.

| `TransportError` | `dream_errors.Error` | Message |
|:---|:---|:---|
| `TimedOut(timeout_ms)` | `Timeout` | `the HTTP request got no response in <timeout_ms> ms` |
| `ConnectFailed(reason)` | `Unavailable` | `the HTTP client could not connect to the server: <reason>` |
| Every other error | `Failed` | `the HTTP request failed: ` and the text of `transport_error_to_string` |

`RemoteClosed` and `ConnectionError` give `Failed`, not `Unavailable`. For both of them, the client reached the server. After `RemoteClosed`, the server can have processed the request, so a blind retry is not safe. A `ResponseError` is not a `TransportError`, because the server answered: read its status to decide what it means for your app. The message is text for developers and logs. Do not show it to the users of an app.

## Step 1: Sort a result into what to do next

Most programs don't care about all nine transport errors. They care about one question: what now? This function answers it once, so the rest of your code doesn't have to:

### Sort a result into done, try later or give up <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_errors_classify.gleam#L5-L45"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, type TransportError, ConnectFailed, Goaway,
  RefusedStream, RemoteClosed, RequestError, ResponseError, StreamReset,
  TimedOut, transport_error_to_string,
}
import gleam/int

pub type Outcome {
  /// The server answered with a status below 400.
  Done(response: HttpResponse)
  /// The request can work later: the server is busy, or the network failed.
  TryLater(reason: String)
  /// Sending the same request again gives the same answer.
  GiveUp(reason: String)
}

pub fn classify(result: Result(HttpResponse, SendError)) -> Outcome {
  case result {
    Ok(response) -> Done(response: response)
    Error(ResponseError(response: response)) -> classify_status(response)
    Error(RequestError(error: error)) -> classify_transport(error)
  }
}

fn classify_status(response: HttpResponse) -> Outcome {
  let reason = "HTTP " <> int.to_string(response.status)
  case response.status {
    408 | 429 | 500 | 502 | 503 | 504 -> TryLater(reason: reason)
    _ -> GiveUp(reason: reason)
  }
}

fn classify_transport(error: TransportError) -> Outcome {
  let reason = transport_error_to_string(error)
  case error {
    ConnectFailed(..) | TimedOut(..) | RemoteClosed | Goaway(..) ->
      TryLater(reason: reason)
    StreamReset(code: RefusedStream, ..) -> TryLater(reason: reason)
    _ -> GiveUp(reason: reason)
  }
}
```

Here's what `classify` returns for real failures:

### What classify returns <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_errors_step_1.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
send(api |> path("/text"))                  -> Done(response)  (status 200)
send(api |> path("/status/404"))            -> GiveUp("HTTP 404")
send(api |> path("/status/503"))            -> TryLater("HTTP 503")
send(api |> port(1))                        -> TryLater("Connection failed: Connection refused")
a server that closes the connection         -> TryLater("Remote closed connection")
an HTTP/2 server that resets the stream     -> GiveUp("Stream reset (internal_error): Stream reset by server.")
```

The status list is a choice, not a rule. 429 (too many requests) and 503 (unavailable) say "later" outright, and 408, 500, 502 and 504 often pass too. Any other 4xx is about your request, and it gets the same answer every time you send it. Adjust the list to the API you call: some APIs send 409 when you should retry.

## Step 2: Set the timeouts

Two settings decide how long a request may take:

- `timeout(ms)` limits how long the client waits for the server: for the response, and between the parts of the body. When the server sends nothing for that long, the request fails with `TimedOut(ms)`. When you don't set it, the request waits up to 30 seconds.
- `connect_timeout(ms)` limits the TCP connect. It defaults to 15 seconds, the `default_connect_timeout` of the transport configuration.

Set both on the request that needs them:

### Wait long enough for a slow report <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_errors_timeouts.gleam#L5-L20"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, connect_timeout, path,
  send, timeout,
}

pub fn fetch_report(
  api: ClientRequest,
  wait_ms: Int,
) -> Result(HttpResponse, SendError) {
  api
  // The mock server answers /slow after 5 seconds
  |> path("/slow")
  |> connect_timeout(2000)
  |> timeout(wait_ms)
  |> send()
}
```

The mock server answers `/slow` after 5 seconds, so:

### A short and a long timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_errors_step_2.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
fetch_report(api, 500)    -> Error(RequestError(TimedOut(500)))
fetch_report(api, 7000)   -> Ok(response)  (status 200, body "Slow response")
```

A short connect timeout with a longer request timeout is a good pairing for most APIs: a server that doesn't accept the connection in 2 seconds probably won't, but a server that's thinking about a big report may need a while to answer.

## Step 3: Decide about redirects

By default the client follows redirects, up to five in a row, and gives you the final answer. `send(api |> path("/redirect/302"))` returns status 200 with the body `Hello, World!`, which is what `/text` answers.

Sometimes you want the redirect itself: to show the user where a short link goes, or to store the new location of a moved resource. Turn redirects off with `auto_redirect(False)` and read the `location` header:

### Read where a redirect points <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_errors_redirects.gleam#L5-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type ClientRequest, auto_redirect, path, send}
import gleam/list
import gleam/result

pub fn redirect_target(
  api: ClientRequest,
  from: String,
) -> Result(String, Nil) {
  use response <- result.try(
    api
    |> path(from)
    |> auto_redirect(False)
    |> send()
    |> result.replace_error(Nil),
  )
  list.find(response.headers, fn(header) { header.name == "location" })
  |> result.map(fn(header) { header.value })
}
```

`redirect_target(api, "/redirect/302")` returns `Ok("/text")`. With redirects off, a 3xx is an `Ok`, because its status is below 400.

A server that redirects in a loop doesn't hang your program. After five redirects the client stops and returns `Error(RequestError(Unexpected("Too many redirects (max 5)")))`.

## Step 4: Retry what is safe to retry

A `TryLater` outcome invites a retry. Two rules make retries safe: wait longer each time, so a struggling server gets room to recover, and repeat only requests that are safe to repeat. A GET, PUT or DELETE has the same effect if it runs twice. A POST that creates an order doesn't: if the first one reached the server and only the answer got lost, a retry makes a second order.

### Retry with a growing wait <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_errors_retry.gleam#L6-L35"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type ClientRequest, get_method, send}
import gleam/erlang/process
import gleam/http
import gleam/list
import snippets/guide_errors_classify.{type Outcome, TryLater, classify}

pub fn send_with_retry(
  request: ClientRequest,
  attempts: Int,
  wait_ms: Int,
) -> Outcome {
  let outcome = classify(send(request))
  let may_repeat = attempts > 1 && is_safe_to_repeat(get_method(request))
  case outcome, may_repeat {
    TryLater(..), True -> {
      process.sleep(wait_ms)
      send_with_retry(request, attempts - 1, wait_ms * 2)
    }
    _, _ -> outcome
  }
}

/// The methods that RFC 9110 calls idempotent: sending one twice has the
/// same effect as sending it once.
fn is_safe_to_repeat(method: http.Method) -> Bool {
  list.contains(
    [http.Get, http.Head, http.Options, http.Trace, http.Put, http.Delete],
    method,
  )
}
```

Against a server that answers 500 every time, with 3 attempts and a first wait of 10 ms:

### Retries against a server that always fails <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_errors_step_4.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
send_with_retry(GET request, 3, 10)    -> TryLater("HTTP 500"), and the server got 3 requests
send_with_retry(POST request, 3, 10)   -> TryLater("HTTP 500"), and the server got 1 request
```

`get_method(request)` reads the method back from the request, so the helper decides from the request alone. If your API supports idempotency keys, a header that lets the server recognize a repeated POST, you can safely retry a POST that carries one. Add `http.Post` to the list only for those requests.

## When the client sends a request again

The client itself sends a request a second time in one situation: the request got no response head because the connection failed under it. A connection in the pool can be closed by the server while it's idle, and the client can't know until it tries. Whether it sends the request again depends on what the client knows about the request, following RFC 9110 section 9.2.2 and RFC 9113 sections 6.8 and 8.7:

| What happened | GET, HEAD, OPTIONS, TRACE, PUT, DELETE | POST, PATCH and other methods |
|:---|:---|:---|
| The connection closed before the response head | Sent once more on a new connection | Sent once. You get `RemoteClosed` |
| The connection's process was stopped from outside | Sent once more | Sent once. You get `ProcessDown("shutdown")` |
| An HTTP/2 server refused the stream with `REFUSED_STREAM` | Sent once more | Sent once more |
| An HTTP/2 GOAWAY ended the stream before the server took it | Sent once more | Sent once more |
| The connection process stopped before it took the request | Sent once more | Sent once more |
| A timeout, a reset with another code, or any other error | Not sent again | Not sent again |

The last three rows are cases where the server provably didn't process the request, so even a POST is safe to send again. In the first two, the server may have processed it, so only an idempotent request goes out again. You can see the difference with a server that reads a request and closes the connection without an answer: it reads a GET twice and a POST once.

The client sends a request again at most once, and only for these failures. It never retries an error status: a 503 comes back to you as `ResponseError`, and the retry is your decision, as in Step 4.

## Test your code

Errors are the part of your code that runs least often in development, so they're the part most worth testing. `dream_mock_server` in config mode answers each path with the status you choose, which makes every `ResponseError` easy to produce. A refused connection needs no server: send to port 1.

Here's a test module for `classify` that covers a status to retry, a status to give up on, and a refused connection. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test classify against failing servers <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_errors_testing.gleam#L5-L66"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{host, path, port, scheme, send}
import dream_mock_server/config.{Exact, MockRoute}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None}
import snippets/guide_errors_classify.{GiveUp, TryLater, classify}

pub fn tests() -> TestSuite {
  describe("classify", [
    it("tries a 503 again later", fn() {
      // Arrange
      let routes = [MockRoute("/report", Exact, None, 503, "Busy")]
      let assert Ok(mock) = server.start_with_config(19_975, routes)

      // Act
      let outcome = classify(send(report_request(19_975)))
      server.stop(mock)

      // Assert
      outcome
      |> should
      |> be_equal(TryLater(reason: "HTTP 503"))
      |> or_fail_with("A 503 should be tried later")
    }),
    it("gives up on a 404", fn() {
      // Arrange
      let routes = [MockRoute("/report", Exact, None, 404, "No such report")]
      let assert Ok(mock) = server.start_with_config(19_976, routes)

      // Act
      let outcome = classify(send(report_request(19_976)))
      server.stop(mock)

      // Assert
      outcome
      |> should
      |> be_equal(GiveUp(reason: "HTTP 404"))
      |> or_fail_with("A 404 does not change when you ask again")
    }),
    it("tries a refused connection again later", fn() {
      // Act
      let outcome = classify(send(report_request(1)))

      // Assert
      outcome
      |> should
      |> be_equal(TryLater(reason: "Connection failed: Connection refused"))
      |> or_fail_with("A refused connection can work later")
    }),
  ])
}

fn report_request(on_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(on_port)
  |> path("/report")
}
```

Each test that starts a server uses its own port, because tests run at the same time.

## Common pitfalls

**Retrying every failure.** *Symptom:* duplicate orders, payments or messages after a network hiccup. *Fix:* retry only `TryLater` outcomes, and only for methods that are safe to repeat, as `send_with_retry` does. The client already follows the same rule for the one retry it does itself.

**Treating a 4xx as a network problem.** *Symptom:* a request that can never work is retried until the attempts run out. *Fix:* a `ResponseError` means the server answered. Read its status before you decide, and give up on a 400, 401, 403 or 404.

**Matching on the error text.** *Symptom:* error handling breaks after an upgrade because a message changed. *Fix:* match on the variants, such as `ConnectFailed(..)` or `TimedOut(..)`, and keep `transport_error_to_string` for logs.

**A timeout that is too short for the endpoint.** *Symptom:* `TimedOut(500)` from an endpoint that works in the browser. *Fix:* `timeout(ms)` must be longer than the slowest answer you accept. Set it per request, so a slow report doesn't make every other request wait that long too.

**Retrying with no wait.** *Symptom:* a busy server gets busier, and every attempt fails the same way within a second. *Fix:* sleep between attempts, and make each wait longer than the last.

## Where to go next

- [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md): POST, PUT and DELETE, and reading the body of a refusal.
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): the same errors for streams, and what a timeout means for a long stream.
- [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): how connections are reused, which is where a closed connection comes from.
- [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md): every timeout and its default.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `SendError`, `TransportError`, `timeout`, `connect_timeout` and `auto_redirect`.
