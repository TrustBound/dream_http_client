# Logging

This guide shows how to set the minimum log level of the log output of dream_http_client.

## Log levels

`log_level(level)` on the transport configuration controls which log messages the connection manager and the HTTP shim of the library emit. It uses OTP's `logger:set_module_level/2`, so the filter applies only to the modules of dream_http_client and does not affect the rest of your application.

- `LogDebug`: all messages, with debug-level detail.
- `LogInfo`: informational messages and above (default). Includes graceful connection closures.
- `LogWarning`: warnings and above only. Unexpected disconnects, decompression failures, and unrecognized content encodings.
- `LogError`: errors only.
- `LogNone`: no log output from dream_http_client.

### Log warnings only <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_log_level.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{LogWarning}

pub fn warnings_only() -> Nil {
  client.transport_config()
  |> client.log_level(LogWarning)
  |> client.configure_transport()
}
```

## See also

- [Transport configuration](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/transport-configuration.md): global settings and their defaults
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle each kind of error
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
