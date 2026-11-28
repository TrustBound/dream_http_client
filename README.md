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

## What is Dream HTTP Client?

Dream HTTP Client calls the APIs your app depends on and hands back exactly what they said. Wait for the whole answer, or take it piece by piece as it arrives, whichever fits the job. Every failure comes back as something you can handle, never a surprise. Record real calls once, and your tests replay them forever without touching the network.

## Features

### Four ways to read a response

One request builder, and the mode that fits the response. [Read more](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md).

| Feature                  | What you get                                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------------------------------ |
| ⏳ **Blocking**          | `send` returns the whole response, or a typed error                                                          |
| 🌊 **Yielder streaming** | `stream_yielder` reads a long or endless response chunk by chunk                                             |
| 🔔 **Callbacks**         | `start_stream` runs `on_stream_start`, `on_stream_chunk`, `on_stream_end` and `on_stream_error` in a process |
| 📬 **Actor messages**    | `stream_to` delivers a stream as typed messages to an OTP actor, with many streams in one actor              |

### Tests without the network

Record a call once, then play it back in every run. [Read more](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md).

| Feature                    | What you get                                                                       |
| -------------------------- | ---------------------------------------------------------------------------------- |
| 🎙️ **Record and playback** | Three modes: `Record`, `Playback` and `Passthrough`                                |
| 🎯 **Request matching**    | Choose which recording answers a request, and see the nearest recordings on a miss |
| 🔐 **Secrets stay out**    | Request and response transformers keep tokens and cookies out of the files         |

### Connections

Shared connections, HTTP/2 and TLS. [Read more](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md).

| Feature                                | What you get                                                                       |
| -------------------------------------- | ---------------------------------------------------------------------------------- |
| 🚀 **HTTP/2 multiplexing**             | Many requests share one connection through gun                                     |
| 🏊 **Pools and limits**                | Connections per host, idle time and timeouts, and a pool of its own for one caller |
| 🛡️ **Private certificate authorities** | Trust an internal authority for one service or for all requests                    |

### Errors and control

Every failure is a value, and every request can be stopped. [Read more](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md).

| Feature                      | What you get                                                              |
| ---------------------------- | ------------------------------------------------------------------------- |
| 🧾 **Typed errors**          | `SendError`, `TransportError` and `StreamFailure` tell each failure apart |
| ⏱️ **Timeouts and redirects** | Set the timeout, the connect timeout and `auto_redirect` for each request |
| ✋ **Cancel a stream**       | `cancel_stream` stops an in-flight request cleanly                        |

## A Quick Example

### Send a request and print the answer <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_getting_started_first_request.gleam#L5-L32"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a> <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/docs/guides/getting-started.md#send-a-request-and-print-the-answer-"><img align="right" alt="Guide: Getting started" title="Guide: Getting started" src="https://img.shields.io/badge/%F0%9F%93%96_read-guide-blue.svg?style=flat-square"></a>

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

**Run this:** `main()` against a server on `localhost:9876` that answers `/text` → prints `Status: 200` and `Body: ` followed by the text of the response.

## Installation

```sh
gleam add dream_http_client
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
- [API reference](https://hexdocs.pm/dream_http_client): every module and function on HexDocs

## Requirements

- Gleam 1.19.2 or newer on Erlang/OTP 28 (the versions CI uses). Dream HTTP Client runs on Erlang, on top of gun.

## About Dream

[Dream](https://github.com/TrustBound/dream) is a collection of Gleam packages for building production web applications. Each package implements its standards completely, shares the same naming and style as the others, and is fully tested. TrustBound builds Dream for its own production systems and shares it in the hope that it helps yours.

Dream HTTP Client works on its own. You don't need the rest of Dream to use it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE.md](https://github.com/TrustBound/dream_http_client/blob/main/LICENSE.md)
