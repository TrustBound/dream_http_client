# Sending data to an API

Reading from an API is only half the job. Sooner or later you create a record, change it, delete it, search for it with a query string, prove who you are with a token, or upload a file. Each of those is a request with something extra in it: a method, a body, a header, a query. This guide builds a small client for a to-do API that does all of that, and shows how to read what the server says back, including when it says no.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [What to set for what you send](#what-to-set-for-what-you-send)
- [Step 1: Create a record with a JSON POST](#step-1-create-a-record-with-a-json-post)
- [Step 2: Change and delete records](#step-2-change-and-delete-records)
- [Step 3: Search with a query string](#step-3-search-with-a-query-string)
- [Step 4: Send a token with every request](#step-4-send-a-token-with-every-request)
- [Step 5: Upload bytes](#step-5-upload-bytes)
- [Step 6: Read headers and refusals](#step-6-read-headers-and-refusals)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- POST a JSON body and see exactly what the server received.
- Send PUT, PATCH and DELETE requests through one small helper.
- Build a query string that survives spaces and `&` in the values.
- Add an `Authorization` header to every request from one place.
- Upload bytes that aren't text.
- Read a response header, and the body of a response that refused your request.

## Before you start

You need the package, and `gleam_json` to build JSON bodies:

```sh
gleam add dream_http_client gleam_json
```

The examples run against [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`. Its `/post`, `/put`, `/patch` and `/delete` endpoints answer with JSON that echoes the method, the path and the body they received, and `/get` echoes the query string. That makes them handy for seeing your request the way the server saw it. The [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code) guide shows how to add and start the mock server.

Every function in this guide takes the API's base request as its first argument, the way [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#step-2-wrap-the-api-in-a-module-of-your-own) builds it. For the mock server, that's the `local_api` of Getting started:

### The base request of the mock server <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_getting_started_api_client.gleam#L30-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// The base request of the API: its scheme, host and port. Every endpoint
/// function starts from it, so one place says where the API lives.
pub fn local_api() -> ClientRequest {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
}
```

## What to set for what you send

| What you send | Set | Why |
|:---|:---|:---|
| JSON, a form, or other text | `body(text)` and a `content-type` header | `body` sends the text as UTF-8 bytes. The client doesn't guess a content type, so say what it is. |
| A file, an image, or any bytes | `body_bits(bytes)` and a `content-type` header | The bytes go out exactly as they are. |
| A token, an API key, a user agent | `add_header(name, value)` | It adds one header and keeps the others. |
| A fixed set of headers | `headers([Header(name, value), ...])` | It replaces every header the request had. |
| Search terms or paging | `query(uri.query_to_string(pairs))` | `query` takes the query string as it is, so let `gleam/uri` encode the values. |

## Step 1: Create a record with a JSON POST

To create something, an API usually wants a POST with a JSON body. Build the JSON with `gleam_json`, set the method and the content type, and give the text to `body`:

### Create a to-do with a JSON POST <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_create.gleam#L5-L25"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, add_header, body,
  method, path, send,
}
import gleam/http
import gleam/json

pub fn create_todo(
  api: ClientRequest,
  title: String,
) -> Result(HttpResponse, SendError) {
  let todo_json =
    json.object([#("title", json.string(title)), #("done", json.bool(False))])

  api
  |> method(http.Post)
  |> path("/post")
  |> add_header("content-type", "application/json")
  |> body(json.to_string(todo_json))
  |> send()
}
```

`create_todo(api, "Buy milk")` returns a response with status 201 and this body, which is the mock server telling you what it got:

### The echo of the new todo <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_sending_data_create.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
{"method":"POST","url":"/post","data":"{\"title\":\"Buy milk\",\"done\":false}"}
```

The `data` field is your JSON, byte for byte. A few things to notice:

- `method(http.Post)` is what makes it a POST. `client.new()` starts as a GET.
- `add_header("content-type", "application/json")` tells the server how to read the body. The client never adds a content type of its own, and many APIs refuse a JSON body without one.
- `send()` returns `Ok` because 201 is below 400. You get the full response, so you can read the new record's ID or its `location` header from it.

## Step 2: Change and delete records

PUT, PATCH and DELETE only differ in the method and the body, so put the common part in one helper and keep each public function to a line or two:

### Replace, change and delete a to-do <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_update.gleam#L5-L49"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, add_header, body,
  method, path, send,
}
import gleam/http
import gleam/json

pub fn replace_todo(
  api: ClientRequest,
  title: String,
) -> Result(HttpResponse, SendError) {
  let todo_json =
    json.object([#("title", json.string(title)), #("done", json.bool(False))])
  send_json(api, http.Put, "/put", todo_json)
}

pub fn mark_done(api: ClientRequest) -> Result(HttpResponse, SendError) {
  send_json(
    api,
    http.Patch,
    "/patch",
    json.object([#("done", json.bool(True))]),
  )
}

pub fn delete_todo(api: ClientRequest) -> Result(HttpResponse, SendError) {
  api
  |> method(http.Delete)
  |> path("/delete")
  |> send()
}

fn send_json(
  api: ClientRequest,
  verb: http.Method,
  to: String,
  payload: json.Json,
) -> Result(HttpResponse, SendError) {
  api
  |> method(verb)
  |> path(to)
  |> add_header("content-type", "application/json")
  |> body(json.to_string(payload))
  |> send()
}
```

Here's what the mock server answers to each:

### The answers to the update, the patch and the delete <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_sending_data_update.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
replace_todo(api, "Buy oat milk") -> 200 {"method":"PUT","url":"/put","data":"{\"title\":\"Buy oat milk\",\"done\":false}"}
mark_done(api)                    -> 200 {"method":"PATCH","url":"/patch","data":"{\"done\":true}"}
delete_todo(api)                  -> 200 {"method":"DELETE","url":"/delete"}
```

`send_json` is private on purpose. The rest of your program calls `mark_done(api)`, not "send this JSON with this method to this path", so the API's details stay in one module.

These methods differ in one more way that matters when a connection fails. PUT and DELETE are idempotent: sending one twice has the same effect as sending it once. POST and PATCH aren't. So when a connection closes before the answer, the client sends a PUT or DELETE once more on a new connection, and returns the error for a POST or PATCH, because the server may already have created the record. [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md#when-the-client-sends-a-request-again) has the details.

## Step 3: Search with a query string

`query()` takes the part of the URL after the `?`, exactly as it'll be sent. User input such as `milk & eggs` has a space and an `&` in it, and both mean something in a URL. Let `uri.query_to_string` encode each value:

### Search with an encoded query <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_search.gleam#L5-L23"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, path, query, send,
}
import gleam/int
import gleam/uri

pub fn search_todos(
  api: ClientRequest,
  words: String,
  page: Int,
) -> Result(HttpResponse, SendError) {
  let query_string =
    uri.query_to_string([#("q", words), #("page", int.to_string(page))])

  api
  |> path("/get")
  |> query(query_string)
  |> send()
}
```

`search_todos(api, "milk & eggs", 2)` sends `/get?q=milk%20%26%20eggs&page=2`, and the mock server echoes:

### The echo of the search <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_sending_data_search.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
{"method":"GET","url":"/get","query":"q=milk%20%26%20eggs&page=2","headers":[]}
```

The `&` in the search term became `%26`, so the server sees one `q` value, not a `q` and a stray ` eggs`.

## Step 4: Send a token with every request

Most APIs want a token in the `Authorization` header. Add it to the base request once, and every endpoint function that starts from that base sends it:

### Add a token and a user agent <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_headers.gleam#L5-L11"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{type ClientRequest, add_header}

pub fn authorized(api: ClientRequest, token: String) -> ClientRequest {
  api
  |> add_header("Authorization", "Bearer " <> token)
  |> add_header("User-Agent", "greeter/1.0")
}
```

Here's the request head that a server receives for `api |> path("/items") |> authorized("test-token-123") |> send()`, apart from the `host` line:

### The request head that the server receives <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_sending_data_headers.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
GET /items HTTP/1.1
content-length: 0
user-agent: greeter/1.0
authorization: Bearer test-token-123
accept-encoding: gzip, deflate
```

Header names go out in lower case, whatever case you write them in. That's fine: HTTP header names don't depend on case. The client also adds `accept-encoding: gzip, deflate` by itself, and when the server compresses the body, `send()` gives you the body already decompressed.

`add_header` keeps the headers that are already there. `headers([...])` replaces all of them, so call it first if you use both.

## Step 5: Upload bytes

`body` is for text. For a file, an image or any other bytes, use `body_bits`, which sends a `BitArray` exactly as it is:

### Upload bytes <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_upload.gleam#L5-L21"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type SendError, add_header, body_bits, method, send,
}
import gleam/http
import gleam/result

pub fn upload(
  api: ClientRequest,
  bytes: BitArray,
) -> Result(BitArray, SendError) {
  api
  |> method(http.Post)
  |> add_header("content-type", "application/octet-stream")
  |> body_bits(bytes)
  |> send()
  |> result.map(fn(response) { response.body })
}
```

Sent to a server that echoes the body, `upload(api, <<137, 80, 78, 71, 0, 255>>)` returns `Ok(<<137, 80, 78, 71, 0, 255>>)`: the same six bytes, including the zero byte and the 255, which aren't valid UTF-8. To upload a file, read it with `simplifile.read_bits(path)` and pass the result.

## Step 6: Read headers and refusals

The response gives you more than a status and a body. `response.headers` is a list of `Header(name, value)`, and when a server refuses a request, its answer usually explains why. These two functions read both:

### Read a header and explain a refusal <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_responses.gleam#L6-L36"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, RequestError, ResponseError,
  transport_error_to_string,
}
import gleam/int
import gleam/list
import gleam/result

/// The value of a response header. gun gives header names in lower case,
/// so look them up in lower case.
pub fn header_value(
  response: HttpResponse,
  name: String,
) -> Result(String, Nil) {
  list.find(response.headers, fn(header) { header.name == name })
  |> result.map(fn(header) { header.value })
}

/// What went wrong, with the body of the server's answer when it refused.
pub fn explain(result: Result(HttpResponse, SendError)) -> String {
  case result {
    Ok(response) -> "Done: " <> int.to_string(response.status)
    Error(ResponseError(response: response)) ->
      "Refused with "
      <> int.to_string(response.status)
      <> ": "
      <> result.unwrap(client.body_text(response), "<not text>")
    Error(RequestError(error: error)) ->
      "No answer: " <> transport_error_to_string(error)
  }
}
```

What they return:

### What the response helpers return <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_sending_data_responses.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
header_value(response, "x-request-id")          -> Ok("req-42")      (the server sent X-Request-Id: req-42)
explain(send(api |> path("/status/422")))       -> "Refused with 422: {\"status\":422}"
explain(send(api |> port(1)))                   -> "No answer: Connection failed: Connection refused"
explain(send(api |> path("/text")))             -> "Done: 200"
```

The important part is `ResponseError(response: response)`. A status of 400 or more comes back as an `Error`, but it still carries the whole response: the status, the headers, and the body with the server's explanation. A validation error from an API is often a JSON body that lists the fields it didn't like. Decode it from `response.body` the same way you decode a success.

## Test your code

Two kinds of server cover everything in this guide:

- **dream_mock_server** echoes the method, the path, the query and the body, so a test can check that your function built the request you meant. The tests of this guide compare the whole echoed body, as the outputs above show.
- **A server you write for one test** checks what the mock server can't, such as the headers. The mock server doesn't echo them, so the tests of this guide use a small TCP server that answers with the request head it read.

For your own tests, the mock server's echo is usually enough. Here's a test module for `create_todo` and `search_todos` that starts a mock server for each test, each on a port of its own. Tests run at the same time, so two tests that start a server on the same port get in each other's way. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test the to-do client against a mock server <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_sending_data_testing.gleam#L6-L70"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{host, port, scheme}
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/result
import snippets/guide_sending_data_create.{create_todo}
import snippets/guide_sending_data_search.{search_todos}

pub fn tests() -> TestSuite {
  describe("to-do API", [
    it("posts the new to-do as JSON", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_974)

      // Act
      let answer =
        create_todo(test_api(19_974), "Buy milk")
        |> result.map(fn(response) { #(response.status, response.body) })
      server.stop(mock)

      // Assert
      answer
      |> should
      |> be_equal(
        Ok(
          #(201, <<
            "{\"method\":\"POST\",\"url\":\"/post\",",
            "\"data\":\"{\\\"title\\\":\\\"Buy milk\\\",\\\"done\\\":false}\"}",
          >>),
        ),
      )
      |> or_fail_with("Expected the echo of the JSON body")
    }),
    it("encodes the search words in the query", fn() {
      // Arrange
      let assert Ok(mock) = server.start(19_977)

      // Act
      let answer =
        search_todos(test_api(19_977), "milk & eggs", 2)
        |> result.map(fn(response) { response.body })
      server.stop(mock)

      // Assert
      answer
      |> should
      |> be_equal(
        Ok(<<
          "{\"method\":\"GET\",\"url\":\"/get\",",
          "\"query\":\"q=milk%20%26%20eggs&page=2\",\"headers\":[]}",
        >>),
      )
      |> or_fail_with("Expected the encoded query")
    }),
  ])
}

fn test_api(mock_port: Int) -> client.ClientRequest {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(mock_port)
}
```

Each test compares the whole body, not just the status. A request with the wrong method or a badly encoded query still gets a 2xx from many servers, and only the body shows the mistake.

## Common pitfalls

**A raw space in the query.** *Symptom:* `Error(RequestError(Unexpected("invalid_uri")))` before anything reaches the server. *Fix:* `query("q=milk and eggs")` isn't a valid URL. Build the query with `uri.query_to_string`, as in [Step 3](#step-3-search-with-a-query-string).

**No content type.** *Symptom:* the API answers 400 or 415 to a JSON body that looks right. *Fix:* the client sends no `content-type` unless you add one. Add `add_header("content-type", "application/json")`.

**Bytes sent to an endpoint that wants text.** *Symptom:* a 400. The mock server's `/post`, for example, answers `{"error":"Request body is not UTF-8 text"}` to the bytes `<<255, 0>>`. *Fix:* send text with `body`, and bytes only to endpoints that take them, with a matching content type.

**Looking up a header in its original case.** *Symptom:* `header_value(response, "X-Request-Id")` returns `Error(Nil)` although the server sent the header. *Fix:* the client gives you header names in lower case. Look them up in lower case.

**`headers()` after `add_header()`.** *Symptom:* the token is missing from the request. *Fix:* `headers([...])` replaces the whole list. Call it before `add_header`, or put every header in the list.

## Where to go next

- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): every error `send()` returns, and when the client sends a request again.
- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): the API module and its tests, from the beginning.
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record these calls against the real API and play them back in tests.
- [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md): keep the token of Step 4 out of your recordings.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `body`, `body_bits`, `add_header`, `headers`, `query` and the rest of the request builder.
