<div align="center">
  <img src="https://raw.githubusercontent.com/TrustBound/dream/main/ricky_and_lucy.png" alt="Ricky Moony and Lucy, a moon shaped mascot for Dream with the star shaped mascot for Gleam, each with cute cartoon eyes and a smile" width="200">

<b>Type-safe HTTP client for Gleam with streaming support</b>

</div>

<br />

<div align="center">
  <a href="https://hex.pm/packages/dream_http_client"><img src="https://img.shields.io/hexpm/v/dream_http_client" alt="Hex Package"></a>
  <a href="https://github.com/TrustBound/dream_http_client/releases"><img src="https://img.shields.io/github/v/release/TrustBound/dream_http_client?label=Release" alt="Latest Release"></a>
  <a href="https://hexdocs.pm/dream_http_client"><img src="https://img.shields.io/badge/hex-docs-lightgreen.svg" alt="HexDocs"></a>
  <a href="https://github.com/TrustBound/dream_http_client/actions/workflows/ci.yml?query=branch%3Amain"><img src="https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TrustBound/dream_http_client/badges/coverage.json" alt="Coverage"></a>
  <a href="https://github.com/TrustBound/dream_http_client/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <a href="https://gleam.run"><img src="https://img.shields.io/badge/gleam-%E2%9C%A8-ffaff3" alt="Gleam"></a>
</div>

<br />

# dream_http_client

**Type-safe HTTP client for Gleam with recording + streaming support.**

A standalone HTTP and HTTPS client built on [gun](https://github.com/ninenines/gun). It supports HTTP/1.1 and HTTP/2 with native multiplexing. It gives blocking requests, yielder streaming, process-based streaming with callbacks, and message-based streaming to OTP actors. It is built with the same quality standards as [Dream](https://github.com/TrustBound/dream), but it is completely independent. Use it in any Gleam project.

## Features

| Feature                   | What you get                                                  |
| ------------------------- | ------------------------------------------------------------- |
| **Four execution modes**  | Blocking, yielder streaming, process-based, and actor messages |
| **OTP-first design**      | Process-based streams work well with OTP                      |
| **Recording/playback**    | Record HTTP calls for tests, debug production, work offline   |
| **Type-safe**             | `Result` types force error handling, with no silent failures  |
| **HTTP/2 ready**          | Native HTTP/2 multiplexing via gun for high concurrency       |
| **Framework-independent** | Zero dependencies on Dream or other frameworks                |
| **Concurrent streams**    | Handle multiple HTTP streams in a single actor                |
| **Stream cancellation**   | Cancel in-flight requests cleanly                             |
| **Builder pattern**       | Consistent, composable request configuration                  |

## Installation

```bash
gleam add dream_http_client
```

## Quick Start

Send a request and print the answer:

### Send a request and print the answer <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_getting_started_first_request.gleam#L5-L32"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/docs/guides/getting-started.md#send-a-request-and-print-the-answer-"><img align="right" alt="Guide" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

## Guides

- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): go from an empty project to a tested module that calls an API and decodes its JSON
- [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md): POST, PUT, PATCH and DELETE JSON, send query strings, tokens and bytes, and read response headers
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): tell each failure apart, set timeouts and redirects, retry safely, and know when the client sends a request again
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a long or endless response chunk by chunk, handle failures, and test it
- [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md): handle a stream as typed messages in an actor that keeps state and answers other messages
- [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): see how connections are shared, use HTTP/2, set limits, give one caller its own pool, and read the log
- [Calling a service with a private certificate authority](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md): trust an internal certificate authority for one service or for all requests, and test it over TLS
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record real API calls once and play them back in tests with no network
- [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md): choose which recording answers a request, and keep tokens and cookies out of the files
- [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md): every request, transport and recorder setting with its default

## API Reference

The full API reference is on [HexDocs](https://hexdocs.pm/dream_http_client). The guides introduce each function where a task needs it.

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
