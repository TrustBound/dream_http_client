# Errors

This guide shows how to handle the errors of a request. All modes use `Result` types for explicit error handling, so there are no silent failures.

## The error type of send

`SendError` is the error from `send()`:

- `ResponseError(response: HttpResponse)`: an HTTP error (4xx or 5xx) with the full response
- `RequestError(error: TransportError)`: a transport failure (connection, timeout, DNS)

`transport_error_to_string(error)` describes a `TransportError` as text. A stream that fails gives a `StreamFailure`, and `stream_failure_to_string(failure)` describes it as text.

## Handle each kind of error

### Handle each kind of error <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/timeout_config.gleam#L5-L38"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  RequestError, ResponseError, host, path, port, scheme, send, timeout,
  transport_error_to_string,
}
import gleam/http
import gleam/int
import gleam/io
import gleam/result

pub fn fetch_text_with_timeout() -> Result(String, String) {
  let request =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> timeout(5000)

  case send(request) {
    Ok(response) ->
      client.body_text(response)
      |> result.replace_error("The body is not text")
    Error(ResponseError(response: response)) -> {
      let message = "HTTP error " <> int.to_string(response.status)
      io.println_error(message)
      Error(message)
    }
    Error(RequestError(error: error)) -> {
      let message = transport_error_to_string(error)
      io.println_error("Request failed: " <> message)
      Error(message)
    }
  }
}
```

## More examples

- [Timeout configuration](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/timeout_config.gleam): custom timeouts

## See also

- [Requests and responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/requests-and-responses.md): build a request and read the response
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): timeouts, redirects, and HTTP versions for one request
- [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a response as a stream of chunks
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
