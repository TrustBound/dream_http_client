# dream_http_client 6.1.0 Release Notes

**Release Date:** 2026-11-26

This release adds `client.to_error`. It maps a `TransportError` to `dream_errors.Error`, the error type that the Dream packages share. An app that uses several Dream packages can then handle their errors with one type.

It is a minor version: it only adds a function and a dependency.

## Key Highlights

- **`client.to_error`**: maps each `TransportError` to `dream_errors.Error`, and keeps the `TransportError` as the cause
- **New dependency**: `dream_errors`, a small package with the shared error type and no other dependency than `gleam_stdlib`

## What's New

### `client.to_error`

`client.to_error(error)` gives a `dream_errors.Error(TransportError)`:

- `TimedOut` gives `Timeout`
- `ConnectFailed` gives `Unavailable`
- Every other error gives `Failed`

`RemoteClosed` and `ConnectionError` give `Failed`, not `Unavailable`, because the client reached the server for both of them. A `ResponseError` is not a `TransportError`, so it has no mapping: read its status in your app. The message is text for developers and logs. Do not show it to the users of an app.

#### Write a log line for a transport error <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/doc_client_to_error.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_errors.{kind_name, message}
import dream_http_client/client.{type TransportError, to_error}

pub fn log_line(error: TransportError) -> String {
  let shared = to_error(error)
  kind_name(shared) <> ": " <> message(shared)
}
```

## Testing

791 tests, 0 failed, 100% line coverage (1318 of 1318 lines), in 154 seconds over one run, with the coverage report on (with the mock server and the edge server). Apple M1 Max, 10 cores, 64 GB, macOS 26.5.1, OTP 29, Gleam 1.19.2.

## Upgrading

Update your dependencies:

```toml
[dependencies]
dream_http_client = ">= 6.1.0 and < 7.0.0"
```

Then run:

```bash
gleam deps update dream_http_client
```

### Migration Guide

No code changes. Every function of 6.0.0 works as before.

## Documentation

- [dream_http_client hexdocs](https://hexdocs.pm/dream_http_client) -- v6.1.0
- [README](https://github.com/TrustBound/dream_http_client/tree/main)
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md#the-shared-error-type)
- [CHANGELOG](https://github.com/TrustBound/dream_http_client/blob/main/CHANGELOG.md)

## Community

- [Discussions](https://github.com/TrustBound/dream/discussions)
- [Report Issues](https://github.com/TrustBound/dream_http_client/issues)
- [Contributing Guide](https://github.com/TrustBound/dream_http_client/blob/main/CONTRIBUTING.md)
