# Streaming a response

Some responses are too big, or too slow, to wait for. A model API sends its answer a few tokens at a time. A download can be larger than the memory you want to spend on it. A log tail or an event feed never ends at all. For all of these, you want to handle the body piece by piece as it arrives, and let go of each piece when you're done with it. That's what streaming gives you, and this guide walks you through it from a first stream to tested code.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which way to stream](#which-way-to-stream)
- [Step 1: Read a stream chunk by chunk](#step-1-read-a-stream-chunk-by-chunk)
- [Step 2: Turn chunks into lines](#step-2-turn-chunks-into-lines)
- [Step 3: Handle a stream that fails](#step-3-handle-a-stream-that-fails)
- [Step 4: Stream in the background with callbacks](#step-4-stream-in-the-background-with-callbacks)
- [Step 5: Stop a stream early](#step-5-stop-a-stream-early)
- [How fast the client reads](#how-fast-the-client-reads)
- [Timeouts on a long stream](#timeouts-on-a-long-stream)
- [Test your streaming code](#test-your-streaming-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Print the chunks of a stream as they arrive.
- Read a feed of JSON lines, including lines that the network splits across two chunks.
- Tell an error status, a dropped connection, a silent server and an unreachable server apart, and report how much arrived before the failure.
- Download a stream to a file in a background process, and wait for the result.
- Take what you need from a stream and stop it.
- Set a timeout that fits a long stream.
- Test all of it against a local mock server and against a recording.

## Before you start

You need the package in your project:

```sh
gleam add dream_http_client
```

Step 2 decodes JSON with `gleam_json`, and Step 4 writes a file with `simplifile`. Add them if your project doesn't have them yet:

```sh
gleam add gleam_json simplifile
```

You also need a server that streams. Every example in this guide talks to [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`, so you can run each one exactly as it's written. Its streaming endpoints send fixed chunks with fixed delays:

| Endpoint | What it sends |
|:---|:---|
| `/stream/fast` | 10 chunks, `Chunk 1\n` to `Chunk 10\n`, one every 100 ms |
| `/stream/slow` | 5 chunks, `Chunk 1\n` to `Chunk 5\n`, one every 2 seconds |
| `/stream/json` | 5 JSON lines, one every 200 ms |
| `/stream/error` | status 500, with 3 lines of body |
| `/stream/drop` | 2 chunks, then the server closes the connection |

To start it, add it as a dev dependency and call `server.start(9876)` before you run the examples, as the [testing section](#test-your-streaming-code) shows. You can also run it on its own: clone its repository and run `make run`, which listens on port 3004, so change the port in the examples to match.

## Which way to stream

The client gives you three ways to read a stream. They all use the same request builder, and they all stream with the same flow control. What differs is which process does the reading.

| Your situation | Use | Why |
|:---|:---|:---|
| A script, a CLI, or a function that can wait until the stream ends | `stream_yielder` | The simplest code: a loop over chunks in your own process. It blocks that process while it waits. |
| A process that must stay free while the stream runs, such as a request handler that starts a download | `start_stream` with callbacks | The stream runs in its own process and calls your functions there. You get a handle to wait for it or to stop it. |
| An OTP actor that keeps state across chunks and handles other messages too | `stream_to` | The stream sends typed messages to your actor's inbox, next to its other messages. |

The third way has its own guide, [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md). In short, `stream_to(request, inbox)` sends `StreamStart`, one `Chunk` for each part of the body, and then exactly one `StreamEnd` or `StreamError` to a `Subject(StreamMessage)`. The stream stops when the actor that started it stops.

This guide covers the first two.

## Step 1: Read a stream chunk by chunk

Start with the yielder. `stream_yielder()` sends the request and gives you a `Yielder` with one item for each chunk of the body. Here's a complete program that prints each chunk as it arrives, with its size:

### Print each chunk as it arrives <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_print_chunks.gleam#L5-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder,
}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/int
import gleam/io
import gleam/result
import gleam/yielder

pub fn print_chunks() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.try_fold(0, print_chunk)
}

fn print_chunk(
  count: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use chunk <- result.map(chunk_result)
  let bytes = bytes_tree.to_bit_array(chunk)
  let text = bit_array.to_string(bytes) |> result.unwrap("<binary>")
  io.print(
    "[" <> int.to_string(bit_array.byte_size(bytes)) <> " bytes] " <> text,
  )
  count + 1
}
```

When you run `print_chunks()`, it returns `Ok(10)` and prints this, one line every 100 ms:

### What print_chunks prints <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_streaming_print_chunks.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
[8 bytes] Chunk 1
[8 bytes] Chunk 2
[8 bytes] Chunk 3
[8 bytes] Chunk 4
[8 bytes] Chunk 5
[8 bytes] Chunk 6
[8 bytes] Chunk 7
[8 bytes] Chunk 8
[8 bytes] Chunk 9
[9 bytes] Chunk 10
```

Here's what each part does:

- The builder calls (`scheme`, `host`, `port`, `path`) describe the request, exactly as they do for `send()`.
- `stream_yielder()` doesn't send anything yet. The request goes out when you take the first item. Each item is a `Result(BytesTree, StreamFailure)`: `Ok(chunk)` for a piece of the body, or `Error(failure)` when the stream breaks.
- `yielder.try_fold` takes the chunks one at a time and stops at the first `Error`. It hands you that error along with whatever you built up so far, and [Step 3](#step-3-handle-a-stream-that-fails) shows why that's handy.
- `print_chunk` handles one chunk and lets go of it. Only the count survives from one chunk to the next, so memory stays flat however long the stream runs.

When the body ends, the yielder ends, and `try_fold` returns `Ok` with the final count. A clean end never shows up as an error.

## Step 2: Turn chunks into lines

Printing raw chunks is fine for a demo. Real feeds send records, such as one JSON object per line, and that's where most streaming bugs live.

**A chunk is not a line.** In the output above, each chunk happens to be one line, because the mock server writes one line at a time and the program reads fast. Nothing guarantees that. When a program reads `/stream/huge` with a 30 ms pause after each chunk, the server's 100 lines arrive in about 50 chunks, many of them 28 or 42 bytes long: two or three lines each. Over a real network, a chunk can also end in the middle of a line, or in the middle of a UTF-8 character.

So if you decode each chunk as one JSON object, your code works in your tests and fails at random in production. The fix is a buffer. Keep the bytes after the last newline, and put them in front of the next chunk. This function splits the complete lines off the front of a buffer:

### Split the complete lines off a buffer <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_json_lines.gleam#L77-L95"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
/// Splits the complete lines off the front of `buffer`. Returns the lines
/// without their newlines, and the bytes after the last newline.
pub fn complete_lines(buffer: BitArray) -> #(List(BitArray), BitArray) {
  collect_lines(buffer, 0, [])
}

fn collect_lines(
  buffer: BitArray,
  index: Int,
  lines: List(BitArray),
) -> #(List(BitArray), BitArray) {
  case buffer {
    <<line:bytes-size(index), "\n", rest:bytes>> ->
      collect_lines(rest, 0, [line, ..lines])
    <<_:bytes-size(index), _, _:bytes>> ->
      collect_lines(buffer, index + 1, lines)
    _ -> #(list.reverse(lines), buffer)
  }
}
```

It works on bytes, not text, so a character that's split across two chunks doesn't break it. Here's what it returns when a line arrives in two pieces:

### A line in two pieces <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_streaming_complete_lines.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
complete_lines(<<"{\"message\":\"first\"}\n{\"mess">>)
  -> #([<<"{\"message\":\"first\"}">>], <<"{\"mess">>)

complete_lines(<<"{\"mess", "age\":\"second\"}\n">>)
  -> #([<<"{\"message\":\"second\"}">>], <<>>)
```

The first call returns the one complete line, and keeps `{"mess` for later. The second call gets those bytes back in front of the next chunk, and the line is whole again.

Now use it in a stream. The fold carries two things from chunk to chunk: how many events it printed, and the bytes that wait for the rest of their line. This code goes in the same module as `complete_lines`:

### Print the message of each JSON line <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_json_lines.gleam#L6-L75"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type StreamFailure, host, path, port, scheme,
  stream_yielder,
}
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/http
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/yielder

pub type FeedError {
  StreamFailed(failure: StreamFailure)
  BadLine(line: BitArray)
}

pub fn print_mock_events() -> Result(Int, FeedError) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/stream/json")
  |> print_events()
}

/// Prints the `message` of each JSON line and returns how many it printed.
pub fn print_events(request: ClientRequest) -> Result(Int, FeedError) {
  use #(count, rest) <- result.try(
    stream_yielder(request)
    |> yielder.try_fold(#(0, <<>>), handle_chunk),
  )
  // The last line of a stream can come without a newline
  case rest {
    <<>> -> Ok(count)
    last_line -> print_lines([last_line], count)
  }
}

fn handle_chunk(
  state: #(Int, BitArray),
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(#(Int, BitArray), FeedError) {
  let #(count, pending) = state
  use chunk <- result.try(result.map_error(chunk_result, StreamFailed))
  let buffer = bit_array.append(pending, bytes_tree.to_bit_array(chunk))
  let #(lines, rest) = complete_lines(buffer)
  use new_count <- result.map(print_lines(lines, count))
  #(new_count, rest)
}

fn print_lines(lines: List(BitArray), count: Int) -> Result(Int, FeedError) {
  list.try_fold(lines, count, print_line)
}

fn print_line(count: Int, line: BitArray) -> Result(Int, FeedError) {
  use message <- result.map(
    json.parse_bits(line, message_decoder())
    |> result.replace_error(BadLine(line)),
  )
  io.println(message)
  count + 1
}

fn message_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}
```

`print_mock_events()` returns `Ok(5)` and prints:

### What print_mock_events prints <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_streaming_json_events.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
JSON event 1
JSON event 2
JSON event 3
JSON event 4
JSON event 5
```

A few things to notice:

- `print_events` takes the request as a parameter. Your program passes a request to the real API, and your tests pass one to a mock server or a recording. You'll use that in [Test your streaming code](#test-your-streaming-code).
- `FeedError` keeps the two kinds of failure apart: the stream broke (`StreamFailed`), or the server sent a line you can't decode (`BadLine`, with the bytes, so you can log them).
- When the stream ends, the buffer can still hold a last line with no newline after it. `print_events` handles that line too, instead of dropping it.
- Server-sent events (SSE) and NDJSON both use this same shape: a buffer, then a split on the separator. SSE separates events with a blank line, so it splits on `\n\n` instead.

## Step 3: Handle a stream that fails

A stream can fail before the first chunk or in the middle of the body, and the fix is different for each case. Each `Error` item holds a `StreamFailure`, and it has two variants:

- `HttpFailure(response)`: the server answered with a status outside 2xx. The client reads the whole error body and gives you the full `HttpResponse`, with the status, the headers (`retry-after`, for example) and the body. You get no chunks in this case.
- `TransportFailure(error)`: the network failed. The `TransportError` inside tells you how: `ConnectFailed` when the client couldn't connect, `TimedOut` when the server went quiet for too long, `RemoteClosed` when the server closed the connection, and a few more for HTTP/2 resets and crashed processes.

Here's a byte counter that turns each of those into a result your program can act on, and that keeps the number of bytes that arrived before the failure:

### Count bytes and tell failures apart <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_failures.gleam#L5-L49"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type StreamFailure, ConnectFailed, HttpFailure, TimedOut,
  TransportFailure, stream_yielder, transport_error_to_string,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/yielder

pub type DownloadError {
  /// The server answered with a status that is not 2xx. No chunk came.
  Refused(status: Int, body: BitArray)
  /// The client could not connect. No chunk came.
  Unreachable(reason: String)
  /// The server sent nothing for `waited_ms` while the client waited.
  Stalled(received: Int, waited_ms: Int)
  /// The connection broke after `received` bytes.
  Broken(received: Int, reason: String)
}

pub fn count_bytes(request: ClientRequest) -> Result(Int, DownloadError) {
  stream_yielder(request)
  |> yielder.try_fold(0, add_chunk)
}

fn add_chunk(
  received: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, DownloadError) {
  case chunk_result {
    Ok(chunk) -> Ok(received + bytes_tree.byte_size(chunk))
    Error(failure) -> Error(describe_failure(failure, received))
  }
}

fn describe_failure(failure: StreamFailure, received: Int) -> DownloadError {
  case failure {
    HttpFailure(response: response) ->
      Refused(status: response.status, body: response.body)
    TransportFailure(error: ConnectFailed(reason: reason)) ->
      Unreachable(reason: reason)
    TransportFailure(error: TimedOut(timeout_ms: timeout_ms)) ->
      Stalled(received: received, waited_ms: timeout_ms)
    TransportFailure(error: error) ->
      Broken(received: received, reason: transport_error_to_string(error))
  }
}
```

The trick is that `try_fold` passes the running total into `add_chunk`. When an `Error` comes, the total is right there to put into the result.

Here's what `count_bytes` returns for each mock endpoint:

### What count_bytes returns for each endpoint <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/outputs/guide_streaming_failures.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
/stream/fast                     -> Ok(81)
/stream/error                    -> Error(Refused(status: 500, body: <<"Error test chunk 1\nError test chunk 2\nError test chunk 3\n">>))
/stream/drop                     -> Error(Broken(received: 26, reason: "Remote closed connection"))
/stream/slow with timeout(500)   -> Error(Stalled(received: 0, waited_ms: 500))
port 1, where nothing listens    -> Error(Unreachable(reason: "Connection refused"))
```

Each one calls for a different response. `Refused` is the server's answer, so read the status and the body before you retry. `Unreachable` means the request never reached the server, so you can try again later. `Stalled` and `Broken` mean you have part of the body. If you need all of it, start again from the beginning, or ask for the rest with a `Range` header if the server supports it.

**An error ends the stream.** After an `Error`, the yielder is done. It doesn't send the request again, and the connection goes back to the pool, so the error is always the last item. That means `yielder.to_list` or `yielder.fold` on a failing stream returns, with the `Error` as the last item it saw. `try_fold` is still the nicer fit when you want to stop at the first error: it gives you the error and the running total in one `Result`, so you don't have to dig through a list to find out what went wrong.

## Step 4: Stream in the background with callbacks

The yielder blocks the process that reads it until the stream ends. That's fine in a script. It isn't fine when the process has other work, such as a web request handler that starts a big download and must answer right away.

For that, use `start_stream()`. It starts a new process for the stream and returns at once. That process calls your callbacks:

- `on_stream_start(fn(headers))`: the response headers arrived.
- `on_stream_chunk(fn(bytes))`: the next part of the body arrived, as a `BitArray`.
- `on_stream_end(fn(trailers))`: the body is complete. The list holds the trailing headers, and is usually empty.
- `on_stream_error(fn(failure))`: the stream failed, with the same `StreamFailure` as in Step 3.

You need only the callbacks you care about. This program downloads `/stream/fast` to a file in the background, then waits for the result:

### Download a stream to a file in the background <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_callbacks.gleam#L6-L54"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  cancel_stream_handle, host, on_stream_chunk, on_stream_end, on_stream_error,
  path, port, scheme, start_stream, stream_failure_to_string,
}
import gleam/erlang/process
import gleam/http
import gleam/io
import gleam/result
import simplifile

pub fn download_to_file(file_path: String) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.write_bits(file_path, <<>>)
    |> result.map_error(simplifile.describe_error),
  )
  let finished = process.new_subject()
  use handle <- result.try(
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/stream/fast")
    // These callbacks run in the stream process, not in this one
    |> on_stream_chunk(fn(chunk) { append_chunk(file_path, chunk) })
    |> on_stream_end(fn(_trailers) { process.send(finished, Ok(Nil)) })
    |> on_stream_error(fn(failure) {
      process.send(finished, Error(stream_failure_to_string(failure)))
    })
    |> start_stream(),
  )
  // This process is free until it waits here
  case process.receive(finished, 60_000) {
    Ok(outcome) -> outcome
    Error(Nil) -> {
      cancel_stream_handle(handle)
      Error("The download did not finish within 60 seconds")
    }
  }
}

fn append_chunk(file_path: String, chunk: BitArray) -> Nil {
  case simplifile.append_bits(file_path, chunk) {
    Ok(Nil) -> Nil
    Error(error) ->
      io.println_error(
        "Cannot write " <> file_path <> ": " <> simplifile.describe_error(error),
      )
  }
}
```

After `download_to_file(path)` returns `Ok(Nil)`, the file holds the whole body, `Chunk 1\n` through `Chunk 10\n`.

It helps to be clear about which process runs what:

- **Your process** builds the request, calls `start_stream()`, and gets the `StreamHandle` back at once. Between that line and `process.receive`, it can do anything else.
- **The stream process** sends the request and runs every callback. `append_chunk` writes to the file there, and `on_stream_end` and `on_stream_error` send the outcome back to your process through the `finished` subject.

A subject is how you wait for the end and learn how it went. If you only need to wait, `await_stream(handle)` blocks until the stream process exits. It returns `Nil`, so it can't tell you whether the stream failed.

Two more things to know:

- `start_stream()` always returns `Ok`. A failure to connect, or an error status, comes through `on_stream_error` like any other failure.
- The stream keeps running after the process that started it stops. If your process gives up, as the 60-second branch does here, stop the stream with `cancel_stream_handle(handle)`, or it runs on without anyone waiting for it.

Callbacks don't carry state from one call to the next. They work well for passing each chunk along: to a file, a socket, or another process. If you need a running total or a parser state across chunks, use the yielder from Step 2, or `stream_to` with an actor that holds the state.

## Step 5: Stop a stream early

Sometimes you have what you need before the stream ends: the first event of a feed, a file's header, or a user who closed the page. With `start_stream()`, call `cancel_stream_handle(handle)`. This function takes the first chunk of a stream and stops the rest:

### Take the first chunk and stop the stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_cancel.gleam#L5-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, cancel_stream_handle, on_stream_chunk, start_stream,
}
import gleam/erlang/process
import gleam/result

pub fn first_chunk(request: ClientRequest) -> Result(BitArray, String) {
  let chunks = process.new_subject()
  use handle <- result.try(
    request
    |> on_stream_chunk(fn(chunk) { process.send(chunks, chunk) })
    |> start_stream(),
  )
  let first = process.receive(chunks, 5000)
  // Stop the stream in both cases: a chunk came, or none came in time
  cancel_stream_handle(handle)
  result.replace_error(first, "No chunk arrived within 5 seconds")
}
```

On `/stream/slow`, `first_chunk` returns `Ok(<<"Chunk 1\n">>)` after about 2 seconds, instead of waiting 10 seconds for the whole stream.

Here's what the cancel does:

- It stops the stream process right away. No callback runs after that: not `on_stream_chunk`, and not `on_stream_end` or `on_stream_error` either. `is_stream_active(handle)` returns `False` once the cancel returns.
- It cancels the request at the server. Over HTTP/1.1, the client closes that connection, so the rest of the body can't reach the next request. Over HTTP/2, the server gets a stream reset and the connection stays open for other requests.
- Chunks that a callback already sent to your process stay in your mailbox. The cancel stops new ones, not the ones that already arrived. Drain them or ignore them.
- A second cancel, or a cancel of a stream that already ended, does nothing.

With the yielder there's no handle. You stop by not taking more items, for example with `yielder.take(1)`. The request then stays open until the process that read it stops, and only then does the client cancel it. In a short-lived process that's fine. In a long-running one, use `start_stream()` so you can cancel the stream when you're done.

For a `stream_to` stream, the matching function is `cancel_stream(request_id)`. It waits until the stream has stopped, so no message of that stream arrives after it returns.

## How fast the client reads

You don't have to do anything to get flow control, but it helps to know what it does, because it changes how a slow consumer behaves.

The client reads the response from the server only as fast as you take chunks. With the yielder, that's each time you take an item. With callbacks, it's each time `on_stream_chunk` returns. At most 16 chunks wait in memory. The rest of the response waits in the network, and the server slows down to match your pace.

Here's what you'll see:

- **Memory stays flat.** A large download that you write to disk holds at most 16 chunks in memory at a time, however large the file is, and even when your disk is slower than the network.
- **A slow consumer slows the server.** If your code needs 50 ms per chunk, the stream runs at that pace. A slow callback doesn't fill memory, and it doesn't cause a timeout either, because the timeout only runs while the client waits for the server. It never runs while it waits for your code.
- **A slow consumer gets bigger chunks.** While your code is busy, data piles up in the network buffers. When the client reads again, one chunk can hold what the server sent in several writes. That's the reason Step 2 needs a buffer.
- **Long streams close their HTTP/1.1 connection.** After a stream of 16 chunks or more over HTTP/1.1, the client closes the connection instead of reusing it. A shorter stream leaves the connection for the next request. HTTP/2 connections stay open.

## Timeouts on a long stream

`timeout(ms)` sets the request timeout, and its default is 30 seconds. For a stream, it limits how long the client waits for the server, not how long the whole stream may run. The clock starts again with each chunk. So a stream can run for hours with a 30-second timeout, as long as the server never goes quiet for 30 seconds while you wait for the next chunk.

This program reads `/stream/slow`, which runs for 10 seconds, with a 3-second timeout:

### Read a 10-second stream with a 3-second timeout <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_long_timeout.gleam#L6-L32"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type StreamFailure, host, path, port, scheme, stream_yielder, timeout,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/http
import gleam/result
import gleam/yielder

pub fn count_slow_chunks() -> Result(Int, StreamFailure) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  // The server sends a chunk each 2 seconds, for 10 seconds in all
  |> path("/stream/slow")
  |> timeout(3000)
  |> stream_yielder()
  |> yielder.try_fold(0, count_chunk)
}

fn count_chunk(
  count: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, StreamFailure) {
  use _chunk <- result.map(chunk_result)
  count + 1
}
```

It returns `Ok(5)`: all five chunks arrive, because the gap between chunks is 2 seconds. With `timeout(500)`, the same stream fails with `TransportFailure(TimedOut(500))`, as Step 3 showed.

To pick a value, think about the longest pause your server makes. A model API can think for a long time before its first token, so give it more than its slowest first response. A log tail that sends nothing while nothing happens needs a timeout longer than its quiet periods, or a server that sends a keep-alive line now and then.

The same timeout also limits the wait for the response headers. The TCP connect has its own limit, `connect_timeout(ms)`, with a default of 15 seconds.

## Test your streaming code

Your streaming code depends on two things you can't control in a unit test: what the server sends, and how the network splits it into chunks. You can test both:

- **Against a mock server**, to test the whole path over a real connection, including failures. `dream_mock_server` sends known chunks with known delays, and has endpoints for an error status (`/stream/error`) and a dropped connection (`/stream/drop`).
- **Against a recording**, to test exact chunk boundaries, the timing between chunks, and an error status, with no network at all. A recording of a stream holds each chunk as it arrived, so you can write one with a line split across two chunks, which no well-behaved test server will do for you.

Add the test dependencies first, under `[dev-dependencies]` in your `gleam.toml`. These are the lines of this package's own `gleam.toml`:

### The test dependencies <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/gleam.toml#L42-L43"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```toml
dream_mock_server = ">= 2.0.0 and < 3.0.0"
dream_test = ">= 3.0.0 and < 4.0.0"
```

Here's a test module for `print_events` from Step 2 that does both. It uses [dream_test](https://hexdocs.pm/dream_test):

### Test print_events with a mock server and a recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.1.0/test/snippets/guide_streaming_testing.gleam#L6-L103"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  host, path, port, recorder as with_recorder, scheme,
}
import dream_http_client/matching
import dream_http_client/recorder.{directory, mode, start}
import dream_http_client/recording.{Chunk, RecordedRequest, StreamingResponse}
import dream_http_client/storage
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/option.{None}
import simplifile
import snippets/guide_streaming_json_lines.{print_events}

const mock_port = 19_970

pub fn tests() -> TestSuite {
  describe("print_events", [
    it("prints the five events of a JSON lines stream", fn() {
      // Arrange
      let assert Ok(mock) = server.start(mock_port)
      let request =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(mock_port)
        |> path("/stream/json")

      // Act
      let printed = print_events(request)
      server.stop(mock)

      // Assert
      printed
      |> should
      |> be_equal(Ok(5))
      |> or_fail_with("Expected five events")
    }),
    it("joins a line that arrives in two chunks", fn() {
      // Arrange
      // Start from an empty directory of recordings
      let recordings = "build/guide_streaming_recordings"
      let assert Ok(Nil) = simplifile.create_directory_all(recordings)
      let assert Ok(Nil) = simplifile.delete(recordings)
      let split_line =
        recording.Recording(
          request: RecordedRequest(
            method: http.Get,
            scheme: http.Https,
            host: "api.example.com",
            port: None,
            path: "/events",
            query: None,
            headers: [],
            body: <<>>,
          ),
          response: StreamingResponse(status: 200, headers: [], chunks: [
            Chunk(data: <<"{\"message\":\"first\"}\n{\"mess">>, delay_ms: 0),
            Chunk(data: <<"age\":\"second\"}\n">>, delay_ms: 0),
          ]),
        )
      let key =
        matching.request_key(
          method: True,
          url: True,
          headers: False,
          body: False,
        )
      let assert Ok(Nil) =
        storage.save_recording_immediately(
          recordings,
          split_line,
          key(split_line.request),
        )
      let assert Ok(playback) =
        recorder.new()
        |> directory(recordings)
        |> mode(recorder.Playback)
        |> start()
      let request =
        client.new()
        |> host("api.example.com")
        |> path("/events")
        |> with_recorder(playback)

      // Act
      let printed = print_events(request)

      // Assert
      printed
      |> should
      |> be_equal(Ok(2))
      |> or_fail_with("Expected both events, the second one joined")
    }),
  ])
}
```

The first test starts its own mock server on port 19970, sends the request there, and stops the server. Because `print_events` takes the request as a parameter, the test needs no special hooks in your code.

The second test writes a recording by hand, with `storage.save_recording_immediately`, and plays it back. The request in the recording must match the request your code sends: same method, scheme, host, port, path and query. That's what the default match key compares, and the test uses the same key to save the recording.

A recording of a stream stores:

- The request: method, scheme, host, port, path, query, headers and body.
- The response status and headers.
- Each chunk, with `delay_ms`, the time since the chunk before it.

You can make recordings from real traffic, too. Attach a recorder in `Record` mode, run your code once against the real API, and commit the files. The [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md) guide shows how. Know what playback does and doesn't do:

- Playback hands over the recorded chunks with the same boundaries, and waits each chunk's `delay_ms` before it hands the chunk over. A slow chunk handler doesn't add to those waits: each chunk is due at its recorded time.
- The request's `timeout` applies in playback just as it does live. A recorded delay longer than the timeout ends the stream with the same `TimedOut` failure a live stream gives.
- A recording with a status outside 2xx plays back as the live client would: one `HttpFailure` with the recorded status, the headers, and all the chunks joined as the body. No chunk and no end event come.
- A stream that fails while you record it isn't saved, and neither is one that you cancel. Record mode never saves a failing status, so you write that recording by hand.
- In playback mode, a request that matches no recording isn't sent. The stream fails with `TransportFailure(NoRecording(method, url, directory, nearest))`, which names the request and the nearest recordings, so you can see which recording is missing and what differs.

So a recording can test how your code handles an error status or a timeout. It can't test a dropped connection: test that against the mock server, as the Step 3 examples do.

## Common pitfalls

**A yielder inside an actor.** *Symptom:* the actor stops answering its other messages until the stream ends, and calls to it time out. *Fix:* `stream_yielder` blocks the process that reads it. In an actor, use `stream_to`, so chunks arrive as messages between the others. See [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md).

**Treating a chunk as a message.** *Symptom:* JSON decode errors that come and go, often only under load or over slow networks. *Fix:* buffer the bytes and split on the separator, as in [Step 2](#step-2-turn-chunks-into-lines). Test the split with a recording that cuts a line in half.

**Dropping the error at the end of the list.** *Symptom:* a download looks complete, but the file is short. *Fix:* `yielder.to_list` on a failing stream returns, and its last item is the `Error`. If you keep only the `Ok` chunks, half a body looks like a whole one. Use `yielder.try_fold`, which stops at the first `Error` and returns it, or check every item.

**Not waiting for a background stream.** *Symptom:* a script exits with half a file, or a test checks the result before the stream ends. *Fix:* `start_stream()` returns before the stream does. Wait for a message from `on_stream_end` and `on_stream_error`, as in [Step 4](#step-4-stream-in-the-background-with-callbacks), or call `await_stream(handle)`.

**A callback that blocks.** *Symptom:* a stream that used to take seconds takes minutes. *Fix:* flow control makes the stream run at the pace of `on_stream_chunk`. That keeps memory flat, but it also means a slow callback, such as a database write for each chunk, slows the whole stream. Do the slow work in batches, or hand each chunk to another process.

**Leaving a stream running.** *Symptom:* connections stay busy after your code has what it needs. *Fix:* a `start_stream()` stream runs until it ends, even after the process that started it stops, so cancel it with `cancel_stream_handle`. A yielder that you stop reading keeps its request open until its process stops.

## Where to go next

- [Streaming into an OTP actor](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming-to-actors.md): handle a stream as typed messages in an OTP actor, with its own state.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md): every error type of the client, for `send()` and for streams.
- [Handling errors, timeouts and retries](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/errors.md#step-2-set-the-timeouts): timeouts and redirects for one request.
- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record real traffic and play it back in tests.
- [Controlling connections](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/connection-pools.md): how streams share connections with other requests.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/client.html): `stream_yielder`, `start_stream`, `stream_to`, `StreamFailure` and the rest of the client.
