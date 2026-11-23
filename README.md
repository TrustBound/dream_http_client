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

Make a simple HTTP request:

### Simple GET request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/blocking_request.gleam#L6-L19"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/docs/guides/getting-started.md#simple-get-request-"><img align="right" alt="Guide" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

## Guides

- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): install the package, send a first request, and choose an execution mode
- [Requests and responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/requests-and-responses.md): build a request, send it, and read the response body
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a long or endless response chunk by chunk, handle failures, and test it
- [Streaming to actors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md): handle a stream as typed messages in an OTP actor
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle HTTP errors and transport failures
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): set timeouts, redirects, and the HTTP version for one request
- [Transport configuration](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/transport-configuration.md): configure the global transport, with every default
- [Connection pools](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): how connections are used, and a pool of its own for a caller
- [TLS and certificate authorities](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/tls-and-certificate-authorities.md): trust a private certificate authority
- [Logging](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/logging.md): set the log level of the client
- [Recording and playback](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record requests and responses and play them back
- [Request matching and scrubbing](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md): match requests to recordings and remove secrets

## API Reference

The full API reference is on [HexDocs](https://hexdocs.pm/dream_http_client). Each guide lists the functions and types it uses.

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
