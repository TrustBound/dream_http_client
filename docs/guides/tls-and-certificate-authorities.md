# Calling a service with a private certificate authority

Public HTTPS sites have certificates from authorities that every operating system trusts, so the client just works with them. Internal services are different. A company network, a Kubernetes cluster or a staging environment often runs its own certificate authority, and your system doesn't know it. Call such a service and the TLS handshake fails before a single byte of HTTP. This guide shows you how to trust a private certificate authority for the requests that need it, or for your whole program, what each failure looks like, and how to test it with a local HTTPS server.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Where to set the certificate authority](#where-to-set-the-certificate-authority)
- [Step 1: See the handshake fail](#step-1-see-the-handshake-fail)
- [Step 2: Trust the private authority for one service](#step-2-trust-the-private-authority-for-one-service)
- [Step 3: Know the failures](#step-3-know-the-failures)
- [Step 4: Trust it for every request](#step-4-trust-it-for-every-request)
- [Step 5: HTTP/2 comes with TLS](#step-5-http2-comes-with-tls)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- See what an untrusted certificate does to a request.
- Build a base request for an internal service that trusts its certificate authority, and only that one.
- Tell a wrong authority file from a missing one.
- Make a private authority the default for the whole program.
- Check that HTTPS gives you HTTP/2 when the server offers it.
- Test all of it against a local HTTPS server with test certificates.

## Before you start

You need the package:

```sh
gleam add dream_http_client
```

You also need the certificate authority of the service, as a PEM file: a text file that starts with `-----BEGIN CERTIFICATE-----`. Your platform team usually publishes it. The examples use a local HTTPS server that answers `GET /tls` with `hello over tls`. Its certificate is for `localhost`, signed by a test certificate authority that the tests make. The [Test your code](#test-your-code) section shows how to run such a server yourself.

## Where to set the certificate authority

| Your situation | Use | Why |
|:---|:---|:---|
| One internal service among public APIs | `certificate_authority_file(path)` on that service's base request | Only those requests trust the private authority. Public APIs keep the system authorities. |
| Every HTTPS request goes to services of one private authority | `default_certificate_authority_file(path)` in the transport configuration | You set it once. A request can still name its own file. |
| Public HTTPS APIs only | Nothing | The client trusts the authorities of your system by default. |

## Step 1: See the handshake fail

Start with what goes wrong. Here's a client for the internal service, with a base request and one endpoint function:

### A client for an internal HTTPS service <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_tls_request.gleam#L7-L25"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError,
  certificate_authority_file, host, path, port, send,
}

/// The base request of the internal service. Every request to it trusts
/// the certificate authority in `ca_file`, and only that one.
pub fn internal_api(service_port: Int, ca_file: String) -> ClientRequest {
  client.new()
  |> host("localhost")
  |> port(service_port)
  |> certificate_authority_file(ca_file)
}

pub fn fetch_greeting(api: ClientRequest) -> Result(HttpResponse, SendError) {
  api
  |> path("/tls")
  |> send()
}
```

Send `fetch_greeting` with a base request that has no certificate authority file, `client.new() |> host("localhost") |> port(service_port)`, and the client checks the server's certificate against your system's authorities. None of them signed it, so the handshake fails:

### The request with no file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_tls_unknown_ca.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Error(RequestError(ConnectFailed("{tls_alert,{unknown_ca,...")))
```

The reason is the error that Erlang's `ssl` application gave, as text. `unknown_ca` is the part to look for: the server's certificate is signed by an authority the client doesn't trust. That's a safety check doing its job. Never turn it off to make the error go away.

## Step 2: Trust the private authority for one service

`internal_api` in the snippet above already has the fix: `certificate_authority_file(ca_file)`. With it, the request trusts the authorities in that file instead of the system's, the same as `curl --cacert`:

### The request with the file of the authority <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_tls_trusted.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
fetch_greeting(internal_api(service_port, "certs/internal-ca.pem"))
  -> Ok(response)  (status 200, body "hello over tls")
```

A few things to know:

- The scheme is HTTPS because `client.new()` starts with HTTPS. A plain HTTP request ignores the file.
- The file replaces the system authorities for that request. It doesn't add to them.
- Requests with different files never share a connection, so trusting one authority for one service doesn't change other requests.

## Step 3: Know the failures

Two mistakes are common, and they look different:

### Two mistakes with the file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_tls_mistakes.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
the file holds another authority   -> Error(RequestError(ConnectFailed("{tls_alert,{unknown_ca,...")))
the file doesn't exist             -> Error(RequestError(ConnectFailed("{options,{cacertfile,\"<the full path>\",{error,enoent}}}")))
```

- A file of the wrong authority gives the same `unknown_ca` as no file at all. If you set a file and still see `unknown_ca`, the file holds the wrong certificate, often the server's own certificate instead of the authority that signed it.
- A missing or unreadable file fails when the client opens the connection, with the full path and `enoent` in the reason. The request builder doesn't read the file, so a wrong path shows up only on the first request.

Both are `ConnectFailed`, so the request never reached the service. Matching on the reason text is fine for a log, but don't build logic on it: it's Erlang's text, and it can change between OTP versions.

## Step 4: Trust it for every request

If every service your program calls is signed by the same private authority, set the file once in the transport configuration:

### Trust the company authority by default <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_tls_default.gleam#L6-L14"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  configure_transport, default_certificate_authority_file,
}

pub fn trust_company_ca(ca_file: String) -> Nil {
  client.transport_config()
  |> default_certificate_authority_file(ca_file)
  |> configure_transport()
}
```

After `trust_company_ca("certs/internal-ca.pem")`, a request with no file of its own trusts that authority: `fetch_greeting(client.new() |> host("localhost") |> port(service_port))` returns status 200. A request that names its own file with `certificate_authority_file` uses its own file instead. `client.get_default_certificate_authority_file(config)` reads the setting back, and it's `None` until you set it.

`configure_transport` applies the whole configuration, so set the default authority in the same configuration as your other transport settings. The [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md#step-5-tune-the-transport-for-a-busy-service) guide explains why.

## Step 5: HTTP/2 comes with TLS

Over HTTPS, the client and the server agree on the protocol during the handshake. The client offers HTTP/2 and HTTP/1.1, and the server picks. The test server offers HTTP/2, so after one `fetch_greeting` the client holds one connection, and it speaks HTTP/2. With `client.protocols(client.Http1Only)` on the base request, the connection speaks HTTP/1.1 instead.

That matters for load: many requests at once to an HTTP/2 service share one connection, as [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md#step-2-share-one-connection-with-http2) shows. You don't have to do anything to get it.

The handshake has its own time limit, `tls_handshake_timeout`, which is 10 seconds by default and part of the transport configuration.

## Test your code

To test TLS code for real, you need an HTTPS server with a certificate for `localhost`, and the authority that signed it. Make the three files once, with the tool your team uses for test certificates, and keep them with your tests: the server's certificate, the server's key, and the authority's certificate. The tests of this guide make them with Erlang's `public_key:pkix_test_data`.

Then start a [mist](https://hexdocs.pm/mist) server with TLS on a free port, and point the client at it. The tests of this guide get the `mist` module from [dream_http_server](https://hexdocs.pm/dream_http_server), Dream's fork of mist with HTTP/2 fixes, and the test module below runs with it. Add it as a dev dependency:

```sh
gleam add --dev dream_http_server
```

Here's a test module for `fetch_greeting`. It takes the three file paths as a `TestFiles` value, so your `tests()` function passes the paths of your files. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test the internal client against a local HTTPS server <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_tls_testing.gleam#L6-L53"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/result
import mist
import snippets/guide_tls_request.{fetch_greeting, internal_api}

/// The test certificate files: the server's certificate and key, and the
/// certificate authority that signed the certificate for "localhost".
pub type TestFiles {
  TestFiles(certfile: String, keyfile: String, ca_file: String)
}

pub fn tests_with(files: TestFiles) -> TestSuite {
  describe("internal API over TLS", [
    it("trusts the server of the test certificate authority", fn() {
      // Arrange
      let assert Ok(server) =
        mist.new(answer)
        |> mist.bind("localhost")
        |> mist.port(19_987)
        |> mist.with_tls(certfile: files.certfile, keyfile: files.keyfile)
        |> mist.start

      // Act
      let greeting =
        fetch_greeting(internal_api(19_987, files.ca_file))
        |> result.map(fn(response) { response.body })
      process.unlink(server.pid)
      process.kill(server.pid)

      // Assert
      greeting
      |> should
      |> be_equal(Ok(<<"hello over tls">>))
      |> or_fail_with("Expected the greeting over TLS")
    }),
  ])
}

fn answer(_request: Request(mist.Connection)) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("hello over tls")))
}
```

`mist.start` links the server to the test process, so the test unlinks it before it stops it. Otherwise stopping the server would stop the test too.

## Common pitfalls

**The server's certificate in place of the authority's.** *Symptom:* `unknown_ca`, although you set a file. *Fix:* the file must hold the certificate of the authority that signed the server's certificate.

**A relative path that depends on where you run.** *Symptom:* `{error,enoent}` in production, but not on your machine. *Fix:* the path is read when the connection opens, relative to the program's working directory. Use an absolute path, or one your release builds from its own directory.

**Setting the default authority, then a transport setting.** *Symptom:* the default authority stops working after another part of the program applies its own transport configuration. *Fix:* `configure_transport` sets every setting. Apply one configuration with all of them.

**Expecting the file to add to the system authorities.** *Symptom:* a request with `certificate_authority_file` fails against a public API. *Fix:* the file replaces the system authorities for that request. Keep public APIs on base requests without the file.

## Where to go next

- [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): how HTTP/2 shares one connection, and how to tune the transport.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): what to do with a `ConnectFailed`.
- [Settings reference](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/settings-reference.md): every setting and its default.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `certificate_authority_file`, `default_certificate_authority_file` and `protocols`.
