# Streaming

This guide shows how to read a response as a stream of chunks, with a yielder or with callbacks in a stream process. To handle a stream as messages in an OTP actor, see [Streaming to actors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md).

## Flow control

Streams have flow control. The client reads from the server only as fast as you take chunks, and at most 16 chunks wait in memory.

## Stream with a yielder

`stream_yielder()` returns a yielder that produces the chunks of the body. It is best for AI/LLM streaming, file downloads, and sequential processing.

### Count the bytes of a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_yielder_basic.gleam#L5-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/result
import gleam/yielder

pub fn count_stream_bytes() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.try_fold(0, add_chunk_size)
}

fn add_chunk_size(
  total: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use chunk <- result.map(chunk_result)
  total + bytes_tree.byte_size(chunk)
}
```

**Note:** This blocks while it waits for chunks. It is not suitable for OTP actors that handle concurrent operations.

## Stream with callbacks

`start_stream()` runs the stream in its own process and calls your callbacks there. It is best for background tasks, concurrent operations, and streams that you can cancel.

### Stream with callbacks <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/stream_messages_basic.gleam#L5-L54"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type Header, type StreamFailure, await_stream, host, on_stream_chunk,
  on_stream_end, on_stream_error, on_stream_start, path, port, scheme,
  start_stream, stream_failure_to_string,
}
import gleam/bit_array
import gleam/http
import gleam/io

pub fn stream_and_print() -> Result(Nil, String) {
  let stream_result =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
    |> on_stream_start(print_stream_start)
    |> on_stream_chunk(print_chunk)
    |> on_stream_end(print_stream_end)
    |> on_stream_error(print_stream_error)
    |> start_stream()

  case stream_result {
    Error(reason) -> Error(reason)
    Ok(stream_handle) -> {
      // Wait for the stream to complete
      await_stream(stream_handle)
      Ok(Nil)
    }
  }
}

fn print_stream_start(_headers: List(Header)) -> Nil {
  io.println("Stream started")
}

fn print_chunk(data: BitArray) -> Nil {
  case bit_array.to_string(data) {
    Ok(text) -> io.print(text)
    Error(Nil) -> io.print("<binary>")
  }
}

fn print_stream_end(_headers: List(Header)) -> Nil {
  io.println("\nStream completed")
}

fn print_stream_error(failure: StreamFailure) -> Nil {
  io.println_error("Stream error: " <> stream_failure_to_string(failure))
}
```

The stream keeps running after the process that started it stops. Use the `StreamHandle` that `start_stream()` returns to wait for the stream or to cancel it.

## Functions and types

**Yielder streaming:**

- `stream_yielder(req) -> Yielder(Result(BytesTree, StreamFailure))`: returns a yielder that produces chunks

**Process-based streaming:**

- `start_stream(req) -> Result(StreamHandle, String)`: starts the stream and returns a handle
- `await_stream(handle) -> Nil`: waits for completion (optional)
- `cancel_stream_handle(handle) -> Nil`: cancels a running stream

**`StreamHandle`**: an opaque identifier for process-based streams

## More examples

- [Yielder streaming](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_yielder_basic.gleam): sequential processing
- [Process-based streaming](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_messages_basic.gleam): callback-driven streaming
- [Stream cancellation](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/stream_cancel.gleam): cancel via `StreamHandle`

## See also

- [Streaming to actors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md): handle a stream as typed messages in an OTP actor
- [Errors](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): handle each kind of error
- [Recording and playback](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record streams and play them back
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
