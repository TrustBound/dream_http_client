# Recording and playback

This guide shows how to record HTTP requests and responses, and how to play them back for testing, debugging, and offline development.

## Modes that support recording

All four execution modes fully support both recording and playback:

| Mode               | Record | Playback |
|:-------------------|:------:|:--------:|
| `send()`           | ✓      | ✓        |
| `stream_yielder()` | ✓      | ✓        |
| `start_stream()`   | ✓      | ✓        |
| `stream_to()`      | ✓      | ✓        |

Streaming recordings capture each chunk along with timing information. `stream_yielder()`, `start_stream()`, and `stream_to()` share the same fixture format, so any of them can play back a recording that one of them made.

## Record and play back a request

### Quick Example <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_basic.gleam#L5-L70"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, host, path, port, recorder as with_recorder,
  scheme, send,
}
import dream_http_client/recorder.{directory, mode, start}
import gleam/http
import gleam/result

pub type RecordingError {
  RecorderFailed(reason: String)
  RequestFailed(error: SendError)
}

// Record real requests
pub fn record_text(
  recordings_directory: String,
) -> Result(HttpResponse, RecordingError) {
  use record_recorder <- result.try(
    recorder.new()
    |> directory(recordings_directory)
    |> mode("record")
    |> start()
    |> result.map_error(RecorderFailed),
  )

  let response =
    client.new()
    |> scheme(http.Http)
    |> host("localhost")
    |> port(9876)
    |> path("/text")
    |> with_recorder(record_recorder)
    |> send()
    |> result.map_error(RequestFailed)

  // The recorder writes each recording in its own process. Stop returns
  // when every recording is on disk.
  use Nil <- result.try(
    recorder.stop(record_recorder)
    |> result.map_error(RecorderFailed),
  )
  response
}

// Playback later (no network)
pub fn play_back_text(
  recordings_directory: String,
) -> Result(HttpResponse, RecordingError) {
  use playback_recorder <- result.try(
    recorder.new()
    |> directory(recordings_directory)
    |> mode("playback")
    |> start()
    |> result.map_error(RecorderFailed),
  )

  // Returns the recorded response
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> with_recorder(playback_recorder)
  |> send()
  |> result.map_error(RequestFailed)
}
```

## Recording modes

- **`"record"`**: records real requests to disk immediately
- **`"playback"`**: returns recorded responses (no network)
- **`"passthrough"`**: no recording or playback

**Important:** The recorder saves each recording immediately when it captures it. `recorder.stop()` is optional and only does cleanup. Recordings are never lost, even if the process crashes.

## Use cases

**Testing:**

### Play back fixtures in tests <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_playback.gleam#L5-L30"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type HttpResponse, type SendError, host, path, port, recorder as with_recorder,
  scheme, send,
}
import dream_http_client/recorder.{type Recorder, directory, mode, start}
import gleam/http

pub fn start_api_playback() -> Result(Recorder, String) {
  recorder.new()
  |> directory("test/fixtures/api")
  |> mode("playback")
  |> start()
}

// Tests run without external dependencies
pub fn fetch_recorded_text(
  playback_recorder: Recorder,
) -> Result(HttpResponse, SendError) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> with_recorder(playback_recorder)
  |> send()
}
```

**Offline development:** Record API responses one time, then work offline with the recorded responses.

**Debugging production:** Record problematic request and response pairs for investigation.

## Recording storage

The recorder stores each recording in its own file (one per request), with a human-readable filename:

- Filename format: `{method}_{host}_{path}_{key_hash}_{content_hash}.json`
- **`key_hash`** groups recordings by request key
- **`content_hash`** prevents overwrites when more than one recording has the same key

```text
mocks/api/GET_localhost__text_a3f5b2_19d0a1.json
mocks/api/POST_localhost__text_c7d8e9_4f22bc.json
```

**Benefits:**

- **O(1) write performance**: no read-modify-write cycles
- **Atomic fixture writes**: readers never see partial recordings
- **Concurrent tests work**: no file contention between parallel tests
- **Easy inspection**: each recording is a separate, readable file
- **Version control friendly**: individual files show clear diffs

## More examples

- [Record and playback](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_basic.gleam): testing without network
- [Playback-only testing](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_playback.gleam): test fixtures without network
- [Recording with stream_yielder()](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_stream_yielder.gleam): record and play back yielder streams
- [Recording with start_stream()](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_start_stream.gleam): record and play back callback streams

## See also

- [Request matching and scrubbing](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md): choose how requests match recordings, and remove secrets
- [Streaming](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md): read a response as a stream of chunks
- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): install the package and choose an execution mode
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
