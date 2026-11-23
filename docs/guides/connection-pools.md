# Connection pools

This guide shows how the client uses connections, and how to give a group of requests a connection pool of its own.

## How connections are used

- An HTTP/1.1 connection carries one request at a time.
- An HTTP/2 connection carries as many requests as the server allows with `SETTINGS_MAX_CONCURRENT_STREAMS`.
- The pool opens a new connection only when every connection to the host is full. At `max_connections`, a request waits for room up to its timeout.
- Streams have flow control. The client reads from the server only as fast as you take chunks, and at most 16 chunks wait in memory.

## A connection pool of its own

By default, every request uses one pool, and `max_connections` limits the connections to each host. Make a pool one time with `client.new_pool()` and give it to requests with `client.pool()`. Those requests share connections only with requests that have the same pool, and the pool has its own limit. A busy caller does not use up the connections of other callers, and a small limit holds one caller back with no change for the others. When the pool is full, a request waits for room up to its timeout.

### Give the model calls their own pool <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_client_pool.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client
import gleam/option.{type Option}

pub fn model_pool() -> client.ConnectionPool {
  client.new_pool(max_connections: 3)
}

pub fn model_request(
  pool: client.ConnectionPool,
  prompt: String,
) -> client.ClientRequest {
  client.new()
  |> client.host("api.llm.example")
  |> client.path("/v1/chat")
  |> client.body(prompt)
  |> client.pool(pool)
}

pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
  client.get_pool(request)
  |> option.map(client.get_pool_max_connections)
}
```

## See also

- [Transport configuration](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/transport-configuration.md): set `max_connections` and the other global settings
- [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a response as a stream of chunks
- [Request settings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-settings.md): timeouts, redirects, and HTTP versions for one request
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
