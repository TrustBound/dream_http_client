# Getting started

Sooner or later your Gleam program needs something that lives behind another service's HTTP API: a price, a user record, a token, an answer from a model. You want to ask for it, get a typed value back, know clearly when it didn't work, and test all of that without the real service. This guide takes you from an empty project to exactly that: a small module that calls an API, decodes its JSON, reports each kind of failure, and has tests that run against a local server.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which function to call](#which-function-to-call)
- [Step 1: Send your first request](#step-1-send-your-first-request)
- [Step 2: Wrap the API in a module of your own](#step-2-wrap-the-api-in-a-module-of-your-own)
- [Step 3: Tell the failures apart](#step-3-tell-the-failures-apart)
- [Step 4: Call it from your program](#step-4-call-it-from-your-program)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Send a GET request and print the status and the body.
- Write an API module with one function, `fetch_greeting`, that returns a Gleam type instead of raw bytes.
- Turn every way the call can fail into one error type with three cases: the API can't be reached, it answered with an error status, or it sent a body you can't read.
- Call that module from your program's `main`.
- Test it against a mock server, including an API that is down and one that sends HTML instead of JSON.

## Before you start

Make a project with `gleam new greeter` and go into its folder. Then add the client. The examples decode JSON with `gleam_json`, so add that too:

```sh
gleam add dream_http_client gleam_json
```

You don't start or configure anything before the first request. The client runs as an OTP application, and Gleam starts it with your program.

Every example talks to [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`, so you can run them exactly as they're written. This guide uses two of its endpoints: `/text` answers `Hello, World!` as plain text, and `/json` answers `{"message":"Hello, World!","success":true}`. The [Test your code](#test-your-code) section shows how to add the mock server as a dev dependency and start it from a test. You can also run it on its own: clone its repository and run `make run`, which listens on port 3004, so change the port in the examples to match.

## Which function to call

The client has one way to build a request and four ways to send it. Pick by what you do with the answer:

| Your situation | Use | Why |
|:---|:---|:---|
| You need the whole answer before you can use it: a JSON API, a small file | `send` | It returns the status, the headers and the complete body in one `Result`. This guide uses it. |
| The body is large, slow or endless, and you handle it piece by piece | `stream_yielder` or `start_stream` | You get each chunk as it arrives. See [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md). |
| An OTP actor must get the stream as messages, next to its other messages | `stream_to` | See [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md). |

All four take the same request, so everything in this guide about building a request applies to them too.

## Step 1: Send your first request

Here's a complete program. It builds a request for `http://localhost:9876/text`, sends it, and prints what came back:

### Send a request and print the answer <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_first_request.gleam#L5-L32"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, host, path, port, scheme, send,
}
import gleam/http
import gleam/int
import gleam/io
import gleam/result
import gleam/string

pub fn main() -> Nil {
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")

  case send(request) {
    Ok(response) -> print_response(response)
    Error(error) -> io.println("The request failed: " <> string.inspect(error))
  }
}

fn print_response(response: HttpResponse) -> Nil {
  let text = client.body_text(response) |> result.unwrap("<not text>")
  io.println("Status: " <> int.to_string(response.status))
  io.println("Body: " <> text)
}
```

Run it with `gleam run`, and it prints:

### What main prints <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_getting_started_step_1.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Status: 200
Body: Hello, World!
```

Here's what happens:

- `client.new()` gives you a request with defaults: method GET, scheme HTTPS, host `localhost`, no path. Each builder function returns a new request with one more setting, so you chain them with `|>`.
- `scheme(http.Http)` matters here, because the mock server speaks plain HTTP. Leave it out and the client tries HTTPS.
- `port(9876)` is needed because the server isn't on the default port. Without it, the client uses 80 for HTTP and 443 for HTTPS.
- `send()` blocks until the whole response has arrived. It returns `Ok(response)` for a status below 400. A status of 400 or more comes back as `Error(ResponseError(response))`, and a request that got no answer at all comes back as `Error(RequestError(error))`.
- `response.body` is a `BitArray`: the exact bytes the server sent. `client.body_text(response)` gives you a `String` when those bytes are valid UTF-8, and `Error(Nil)` when they aren't.

## Step 2: Wrap the API in a module of your own

Printing a body is fine for a first try. In a real program you don't want HTTP details in every function that needs a greeting. You want one module that knows how to talk to the API and gives the rest of the program a Gleam value.

Here's that module. It knows where the API lives, sends the request, and decodes the JSON into a `Greeting`:

### Fetch a greeting and decode its JSON <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_api_client.gleam#L6-L61"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type TransportError, RequestError, ResponseError, path,
  send,
}
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/result

pub type Greeting {
  Greeting(message: String, success: Bool)
}

pub type ApiError {
  /// The request did not get an answer: no connection, a timeout, a
  /// connection that closed.
  Unreachable(error: TransportError)
  /// The server answered with a status of 400 or more.
  BadStatus(status: Int)
  /// The server answered 2xx, but the body is not the JSON we expect.
  BadBody(error: json.DecodeError)
}

/// The base request of the API: its scheme, host and port. Every endpoint
/// function starts from it, so one place says where the API lives.
pub fn local_api() -> ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
}

pub fn fetch_greeting(api: ClientRequest) -> Result(Greeting, ApiError) {
  use response <- result.try(
    api
    |> path("/json")
    |> send()
    |> result.map_error(to_api_error),
  )
  json.parse_bits(response.body, greeting_decoder())
  |> result.map_error(BadBody)
}

fn to_api_error(error: client.SendError) -> ApiError {
  case error {
    ResponseError(response: response) -> BadStatus(status: response.status)
    RequestError(error: transport_error) -> Unreachable(error: transport_error)
  }
}

fn greeting_decoder() -> decode.Decoder(Greeting) {
  use message <- decode.field("message", decode.string)
  use success <- decode.field("success", decode.bool)
  decode.success(Greeting(message: message, success: success))
}
```

`fetch_greeting(local_api())` returns:

### The greeting <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_getting_started_step_2.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Ok(Greeting("Hello, World!", True))
```

A few choices in this module are worth copying:

- **The base request is a parameter.** `local_api()` holds the scheme, host and port, and `fetch_greeting` takes it as an argument. Your program passes a base request for the real API. Your tests pass one for a mock server. Nothing else changes, and you need no test hooks in the module.
- **One error type for the whole API.** Callers handle `ApiError`, not the client's `SendError` and `json.DecodeError` separately. `to_api_error` is the one place that maps the client's errors into yours.
- **The body is decoded from bytes.** `json.parse_bits` reads `response.body` directly, so you never turn it into a `String` first.

## Step 3: Tell the failures apart

Each case of `ApiError` asks for a different reaction from your program, so it pays to keep them apart. Here's what `fetch_greeting` returns in each situation:

### What fetch_greeting returns in each case <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_getting_started_step_3.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
the API answers its greeting       -> Ok(Greeting("Hello, World!", True))
nothing listens on the port        -> Error(Unreachable(ConnectFailed("Connection refused")))
the API answers 503                -> Error(BadStatus(503))
the API answers <html></html>      -> Error(BadBody(UnexpectedByte("0x3C")))
```

- `Unreachable` means the request got no answer. The `TransportError` inside says why: `ConnectFailed` when the client couldn't connect, `TimedOut` when the server went quiet, `RemoteClosed` when it closed the connection. This is often temporary, so it's the case where a later retry makes sense.
- `BadStatus` means the server answered, and said no. A 404 won't go away if you ask again. A 503 might.
- `BadBody` means the server answered 2xx with something you didn't expect. It's usually a sign that the API changed, or that you're talking to the wrong server, for example a login page in front of the API.

To show an error to a person or write it to a log, add one function to the module that turns it into a message:

### Describe an API error <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_api_client.gleam#L63-L72"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// A message about the error, for a log or for the person who waits.
pub fn describe_api_error(error: ApiError) -> String {
  case error {
    Unreachable(error: transport_error) ->
      "Cannot reach the API: "
      <> client.transport_error_to_string(transport_error)
    BadStatus(status: status) -> "The API answered " <> int.to_string(status)
    BadBody(error: _) -> "The API sent a body that is not a greeting"
  }
}
```

For the unreachable case it returns `Cannot reach the API: Connection failed: Connection refused`, and for the 503 it returns `The API answered 503`. `client.transport_error_to_string` writes the part about the transport error, so you don't have to match each variant just to log it.

One thing the client does for you: when a connection closes before the server answers, it sends a GET once more on a new connection, because a GET is safe to repeat. It doesn't do that for a POST. The [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md) guide has the full rule.

## Step 4: Call it from your program

Your `main`, or a request handler, or an actor, now calls one function and handles one error type:

### Print the greeting or the error <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_main.gleam#L5-L15"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import gleam/io
import snippets/guide_getting_started_api_client.{
  describe_api_error, fetch_greeting, local_api,
}

pub fn main() -> Nil {
  case fetch_greeting(local_api()) {
    Ok(greeting) -> io.println(greeting.message)
    Error(error) -> io.println_error(describe_api_error(error))
  }
}
```

With the mock server running, it prints `Hello, World!`. When the call fails, it prints the message of `describe_api_error` to standard error instead, for example `Cannot reach the API: Connection failed: Connection refused`.

In a real program, `local_api()` is where the API's address comes from. Read the host from an environment variable or your config there, and the rest of the program never needs to know.

## Test your code

Because `fetch_greeting` takes the base request as a parameter, you can point it at any server. `dream_mock_server` gives you two kinds:

- `server.start(port)` starts a server with built-in endpoints, such as `/json`.
- `server.start_with_config(port, routes)` starts a server that answers only the routes you give it, each with its own status and body. That's how you make an API that is down, or one that sends HTML.

Add the test dependencies first, under `[dev-dependencies]` in your `gleam.toml`. These are the lines of this package's own `gleam.toml`:

### The test dependencies <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/gleam.toml#L42-L43"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
dream_mock_server = ">= 2.0.0 and < 3.0.0"
dream_test = ">= 3.0.0 and < 4.0.0"
```

Here's a test module for `fetch_greeting` with one test for the greeting and one for each failure that a server can cause. It uses [dream_test](https://hexdocs.pm/dream_test):

### Test fetch_greeting against mock servers <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_testing.gleam#L6-L65"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{port}
import dream_mock_server/config.{Exact, MockRoute}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/json
import gleam/option.{None}
import snippets/guide_getting_started_api_client.{
  BadBody, BadStatus, Greeting, fetch_greeting, local_api,
}

pub fn tests() -> TestSuite {
  describe("fetch_greeting", [
    it("decodes the greeting of the API", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_971)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_971))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Ok(Greeting(message: "Hello, World!", success: True)))
      |> or_fail_with("Expected the greeting of the mock server")
    }),
    it("reports the status of an API that is down", fn() {
      // Arrange
      let routes = [MockRoute("/json", Exact, None, 503, "Down for repairs")]
      let assert Ok(mock) = server.start_with_config(19_972, routes)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_972))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Error(BadStatus(status: 503)))
      |> or_fail_with("Expected BadStatus(503)")
    }),
    it("reports a body that is not JSON", fn() {
      // Arrange
      let routes = [MockRoute("/json", Exact, None, 200, "<html></html>")]
      let assert Ok(mock) = server.start_with_config(19_973, routes)

      // Act
      let greeting = fetch_greeting(local_api() |> port(19_973))
      server.stop(mock)

      // Assert
      greeting
      |> should
      |> be_equal(Error(BadBody(error: json.UnexpectedByte("0x3C"))))
      |> or_fail_with("Expected BadBody for an HTML body")
    }),
  ])
}
```

Each test starts its own server on its own port and stops it again, so the tests can run at the same time without getting in each other's way. The unreachable case needs no server at all: a base request with `port(1)` is enough, as Step 3 showed.

## Common pitfalls

**Leaving out the scheme.** *Symptom:* `Error(RequestError(ConnectFailed(reason: "closed")))` from a server you know is running. *Fix:* `client.new()` defaults to HTTPS, and a plain HTTP server closes the connection when the TLS handshake starts. Add `scheme(http.Http)` for a plain HTTP server.

**Putting the URL in `host`.** *Symptom:* `Error(RequestError(ConnectFailed(reason: "DNS resolution failed (NXDOMAIN)")))`. *Fix:* `host` takes only the host name, such as `"localhost"` or `"api.example.com"`. Set the scheme, port and path with their own functions.

**Forgetting the port.** *Symptom:* `Error(RequestError(ConnectFailed(reason: "Connection refused")))` when the server runs on a port like 9876. *Fix:* without `port()`, the client uses 80 for HTTP and 443 for HTTPS. Set the port when the server uses another one.

**Treating every `Ok` as success.** *Symptom:* your code tries to decode a redirect page. *Fix:* `send()` returns `Ok` for every status below 400, which includes 3xx when you turn off redirects. The client follows redirects by default, so you only see a 3xx when you ask for it. Check `response.status` when it matters to you.

## Where to go next

- [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md): POST and PUT JSON, add headers and query strings, and read response headers.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): every error the client returns, timeouts, redirects, and when the client sends a request again.
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a large or endless body chunk by chunk.
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record a real API once and replay it in your tests.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `send`, `HttpResponse`, `SendError` and the rest of the client.
