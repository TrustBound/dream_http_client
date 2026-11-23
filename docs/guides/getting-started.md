# Getting started

This guide shows how to add dream_http_client to a Gleam project, send a first request, and pick the execution mode that fits your work.

## Install

Add the package as a dependency:

```bash
gleam add dream_http_client
```

dream_http_client has no dependency on Dream or other frameworks. You can use it in any Gleam project.

## Send a first request

Build a request with `client.new()` and the builder functions, then send it with `send()`:

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

`send()` returns a `Result`. The [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md) guide shows how to handle each kind of error.

## Execution modes

dream_http_client gives four execution modes. Choose the mode that fits your use case:

1. **Blocking, `send()`**: best for JSON APIs and small responses. See [Requests and responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/requests-and-responses.md).
2. **Yielder streaming, `stream_yielder()`**: best for AI/LLM streaming, file downloads, and sequential processing. See [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md).
3. **Process-based streaming, `start_stream()`**: best for background tasks, concurrent operations, and streams that you can cancel. See [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md).
4. **Message-based streaming for OTP actors, `stream_to()`**: best for OTP actors that handle a stream as messages, next to their other messages. See [Streaming to actors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md).

### Choosing a mode

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

All four modes support recording and playback. See [Recording and playback](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md).

## Tested examples

All examples are tested and verified. See [test/snippets/](https://github.com/TrustBound/dream_http_client/tree/main/test/snippets) for complete, runnable code. `make check-snippets` checks that every code block in the docs matches its tested snippet.

## See also

- [Requests and responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/requests-and-responses.md): build a request and read the response
- [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a response as a stream of chunks
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle each kind of error
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
