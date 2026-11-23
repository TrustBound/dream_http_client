# Requests and responses

This guide shows how to build a request with the builder functions, send it with `send()`, and read the response. Use `send()` for JSON APIs and small responses.

## Build a request

Start with `client.new()` and set each part of the request with a builder function. Each function returns a new request, so you can chain them with `|>`.

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

## Request and response bodies

`response.body` is a `BitArray`: the exact bytes the server sent. A body is not always text. `client.body_text(response)` returns the body as a `String` when it is valid UTF-8.

A request body is bytes too. `client.body(text)` sets a text body, and `client.body_bits(bytes)` sets a body that is not text, such as a file.

## Send a request

`send()` blocks until the whole response arrives, then returns it with its status, headers, and body.

### Send and handle errors <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_send.gleam#L5-L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  RequestError, ResponseError, host, path, port, scheme, send,
  transport_error_to_string,
}
import gleam/http
import gleam/int
import gleam/result

pub fn fetch_text() -> Result(String, String) {
  let result =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> send()

  case result {
    Ok(response) ->
      client.body_text(response)
      |> result.replace_error("The body is not text")
    Error(ResponseError(response: response)) ->
      Error("HTTP error " <> int.to_string(response.status))
    Error(RequestError(error: error)) -> Error(transport_error_to_string(error))
  }
}
```

## Functions and types

- `send(req) -> Result(HttpResponse, SendError)`: returns the complete response (status, headers, body)

**`Header`**: an HTTP header with `name: String` and `value: String`

**`HttpResponse`**: a complete HTTP response with `status: Int`, `headers: List(Header)`, and `body: BitArray`

**`SendError`**: the error from `send()`. The [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md) guide shows each variant.

## More examples

- [Blocking request](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/blocking_request.gleam): simple GET
- [POST with JSON](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/post_json.gleam): JSON body
- [Request builder](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/request_builder.gleam): full configuration

## See also

- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): install the package and choose an execution mode
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): timeouts, redirects, and HTTP versions for one request
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle each kind of error
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
