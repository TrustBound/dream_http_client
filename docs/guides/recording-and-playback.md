# Testing with recorded responses

Tests that call a real API are slow, they fail when the network or the API has a bad day, and some APIs cost money per call. Mock servers help, but they answer what you told them, not what the API really says. A recording sits in between: you call the real API once, the client saves each request and its response to a file, and from then on your tests play those files back with no network at all. This guide shows you how to record, how to play back, what happens when a recording is missing, and how to write a recording by hand for the responses that are hard to get from a real API.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which mode to use](#which-mode-to-use)
- [Step 1: Record a real call](#step-1-record-a-real-call)
- [Step 2: Play it back with no network](#step-2-play-it-back-with-no-network)
- [Step 3: Record and play back a stream](#step-3-record-and-play-back-a-stream)
- [Step 4: When no recording matches](#step-4-when-no-recording-matches)
- [Step 5: Write a recording by hand](#step-5-write-a-recording-by-hand)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- Record a request and its response to a file, with code that doesn't know it's being recorded.
- Play the recording back while the server is down.
- Record a stream and play back its chunks with the same boundaries.
- See the error you get when a request has no recording.
- Write a 429 recording by hand, to test how your code handles a rate limit.
- Test an API function against recordings committed to your repository.

## Before you start

You need the package:

```sh
gleam add dream_http_client
```

The examples record from [dream_mock_server](https://github.com/TrustBound/dream_mock_server), standing in for the real API. Its `/text` endpoint answers `Hello, World!`, and `/stream/fast` sends 10 chunks, `Chunk 1\n` to `Chunk 10\n`. The [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code) guide shows how to add and start it.

The idea that makes recordings easy is the one from Getting started: your API functions take a base request as a parameter. A recorder rides along on that base request, so the functions don't change at all.

## Which mode to use

A recorder runs in one of three modes. You pick one with a `recorder.Mode` value when you start it:

| Your situation | Mode | What the client does |
|:---|:---|:---|
| You want new recordings from the real API | `recorder.Record` | Sends each request to the network, and saves the request and its response to a file at once. |
| Tests that must run without the network | `recorder.Playback` | Answers each request from a recording, and sends nothing. A request with no recording fails with `NoRecording`. |
| A recorder is attached, but you want plain requests for now | `recorder.Passthrough` | Sends each request to the network, and saves nothing. |

`recorder.new()` starts in `Passthrough` mode. To read the mode from a text, for example from an environment variable, use `recorder.parse_mode`: it accepts `"record"`, `"playback"` and `"passthrough"`, and returns an `Error` for any other text. `recorder.is_record_mode(recorder)` tells you whether a running recorder records, for code that does something extra while it records.

## Step 1: Record a real call

Here are the two pieces: a function that starts a recorder, and an API function that knows nothing about recorders:

### Start a recorder and call the API <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_client.gleam#L6-L44"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, path, send, transport_error_to_string,
}
import dream_http_client/recorder.{type Recorder, directory, mode, start}
import gleam/int
import gleam/result

/// Starts a recorder in `recorder_mode` (`Record`, `Playback` or
/// `Passthrough`) that keeps its recordings in `recordings`.
pub fn start_recorder(
  recorder_mode: recorder.Mode,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(recorder_mode)
  |> start()
}

/// The text at /text. The code under test doesn't know about recorders:
/// the base request carries one, or doesn't.
pub fn fetch_text(api: ClientRequest) -> Result(String, String) {
  use response <- result.try(
    api
    |> path("/text")
    |> send()
    |> result.map_error(describe_send_error),
  )
  client.body_text(response) |> result.replace_error("The body is not text")
}

fn describe_send_error(error: client.SendError) -> String {
  case error {
    client.ResponseError(response: response) ->
      "HTTP " <> int.to_string(response.status)
    client.RequestError(error: transport_error) ->
      transport_error_to_string(transport_error)
  }
}
```

To record, start a recorder in `Record` mode, put it on the base request with `client.recorder`, and stop it when you're done with it:

### Record the text once <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_round_trip.gleam#L10-L19"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn record_text(
  api: ClientRequest,
  recordings: String,
) -> Result(String, String) {
  use recording <- result.try(start_recorder(recorder.Record, recordings))
  let text = fetch_text(api |> with_recorder(recording))
  // Ends the recorder process: the recording is already on disk
  use Nil <- result.try(recorder.stop(recording))
  text
}
```

`record_text(api, "test/recordings")` returns `Ok("Hello, World!")`. The request went to the server, and `fetch_text` got the live answer. The recorder also wrote it to a file in `test/recordings`, one file for each request:

### The name of a recording file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_recording_file_name.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
GET_localhost__text_<key hash>.json
```

The name starts with the method, the host and the path, so you can find a recording by eye. The key hash comes from the request's match key, and not from the response. So a request keeps its file name when you record it again, and `git diff` shows only what changed in the response.

A record run replaces the recording of each request that it records again. At start, the recorder reads the recordings in its directory. The first time the run records a request, the recorder removes the files that held the same match key, then writes the new file. If the run records the same request two times, the second response replaces the first. The files of the requests that the run does not record stay, so you can record again with one test and keep the rest. A file in the directory that the recorder can't read or decode stops `start` with an error that names the file.

A recorded call returns only when its file is on disk: `send` returns after the write, and a stream ends after the write. So you can read the files, or start a playback recorder on them, right after the call. `recorder.stop` only ends the recorder process. If the recorder can't write the file, the call fails with that error in place of the response: `send` returns `Error(RequestError(Unexpected("Failed to save recording: ...")))`, and a stream ends with a `TransportFailure` with the same `Unexpected`.

## Step 2: Play it back with no network

Now stop the server, start a recorder in `Playback` mode on the same directory, and call the same function:

### Play the text back <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_round_trip.gleam#L21-L27"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
pub fn play_back_text(
  api: ClientRequest,
  recordings: String,
) -> Result(String, String) {
  use playback <- result.try(start_recorder(recorder.Playback, recordings))
  fetch_text(api |> with_recorder(playback))
}
```

With the server stopped:

### Played back with the server stopped <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_recording_step_2.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
play_back_text(api, "test/recordings")   -> Ok("Hello, World!")
fetch_text(api)                           -> Error("Connection failed: Connection refused")
```

With the recorder, `fetch_text` gets the recorded answer, although nothing listens on the port any more. Without it, the same call can't connect. The playback recorder reads every recording in the directory when it starts, and finds the one for each request by its match key: by default, the method and the URL (scheme, host, port, path and query). Headers and body don't count, which you can change: see [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md).

## Step 3: Record and play back a stream

Recording works the same for `stream_yielder`, `start_stream` and `stream_to`. A recording of a stream keeps each chunk on its own, with the time since the chunk before it. Here's a function that reads all the chunks of a stream:

### Read every chunk of a stream <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_stream.gleam#L5-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  type ClientRequest, type StreamFailure, path, stream_yielder,
}
import gleam/bytes_tree
import gleam/list
import gleam/result
import gleam/yielder

pub fn fetch_chunks(
  api: ClientRequest,
) -> Result(List(BitArray), StreamFailure) {
  api
  |> path("/stream/fast")
  |> stream_yielder()
  |> yielder.to_list()
  |> result.all()
  |> result.map(list.map(_, bytes_tree.to_bit_array))
}
```

Recorded from `/stream/fast` and played back with the server stopped, `fetch_chunks` returns the same ten chunks, with the same boundaries:

### The chunks played back <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_recording_stream.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Ok([<<"Chunk 1\n">>, <<"Chunk 2\n">>, <<"Chunk 3\n">>, <<"Chunk 4\n">>, <<"Chunk 5\n">>, <<"Chunk 6\n">>, <<"Chunk 7\n">>, <<"Chunk 8\n">>, <<"Chunk 9\n">>, <<"Chunk 10\n">>])
```

Playback also waits the recorded time before each chunk, so a test sees the stream at the pace it really came. The [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#test-your-streaming-code) guide covers what that means for timeouts, error statuses and streams that fail while you record.

## Step 4: When no recording matches

In playback mode, a request with no recording isn't sent anywhere. It fails, and the error names the request. A GET of `/json`, which the recordings above don't have, through the playback recorder returns:

### A request with no recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_recording_no_recording.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Error(RequestError(NoRecording("GET", "http://localhost:19996/json")))
```

`transport_error_to_string` writes it as `No recording matches GET http://localhost:19996/json`. The streaming functions report it as `TransportFailure(NoRecording(..))`: `stream_yielder` yields it once and ends, `start_stream` calls only `on_stream_error`, and `stream_to` sends only `StreamError`.

That's the error you see when a test calls an endpoint you never recorded, or when the request changed since you recorded it, for example a new query parameter. Record again, or fix the request.

In `Passthrough` mode, the same request goes to the network, and `recorder.get_recordings` stays empty.

## Step 5: Write a recording by hand

Some responses are hard to get from a real API on purpose: a 429 rate limit, a 503 during maintenance, a body with a field that's rare. Write those recordings yourself. A `Recording` is a `RecordedRequest` and a `RecordedResponse`, and `storage.save_recording_immediately` writes it in the same form the recorder does:

### Save a 429 recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_by_hand.gleam#L6-L39"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recording.{BlockingResponse, RecordedRequest, Recording}
import dream_http_client/storage
import gleam/http
import gleam/option.{None, Some}

pub fn save_rate_limit_recording(recordings: String) -> Result(Nil, String) {
  let rate_limited =
    Recording(
      request: RecordedRequest(
        method: http.Get,
        scheme: http.Http,
        host: "localhost",
        port: Some(9876),
        path: "/text",
        query: None,
        headers: [],
        body: <<>>,
      ),
      response: BlockingResponse(
        status: 429,
        headers: [#("retry-after", "30")],
        body: <<"Slow down">>,
      ),
    )
  // The key must be the one the recorder uses: method and URL by default
  let key =
    matching.request_key(method: True, url: True, headers: False, body: False)
  storage.save_recording_immediately(
    recordings,
    rate_limited,
    key(rate_limited.request),
  )
}
```

`save_rate_limit_recording("test/recordings")` writes `GET_localhost__text_7646ad0d38469745.json`, with this content:

### The file of the 429 <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_recording_by_hand.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
{"version":"1.0","entries":[{"request":{"method":"GET","scheme":"http","host":"localhost","port":9876,"path":"/text","query":null,"headers":[],"body":""},"response":{"mode":"blocking","status":429,"headers":[["retry-after","30"]],"body":"Slow down"}}]}
```

Played back, `fetch_text` returns `Error("HTTP 429")`, so you can test what your code does with a rate limit without ever hitting one. A `StreamingResponse(status, headers, chunks)` in place of `BlockingResponse` makes a stream recording, with a `Chunk(data, delay_ms)` for each chunk.

The key you pass to `save_recording_immediately` must be the key the playback recorder uses, or the file name won't match what a record run replaces. The file of a key replaces an earlier file with the same name. The default key is `matching.request_key(method: True, url: True, headers: False, body: False)`.

You can also add a recording to a running recorder with `recorder.add_recording(recorder, recording)`. In record mode, the recorder writes it and keeps it, and `add_recording` returns `Ok(Nil)` when the file is on disk, or `Error` with the write error. In playback mode, `add_recording` does nothing: `recorder.get_recordings` stays as it was, so write the file before you start the playback recorder.

To check recording files with a script, read them with `recording.decode_recording_file`. It turns the JSON of a file into a `RecordingFile`, with a `version` and a list of `entries`:

### Read the statuses of a recording file <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_inspect.gleam#L6-L17"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/recording
import gleam/list
import gleam/result
import simplifile

pub fn recorded_statuses(file_path: String) -> Result(List(Int), String) {
  use json_text <- result.try(
    simplifile.read(file_path) |> result.map_error(simplifile.describe_error),
  )
  use file <- result.map(recording.decode_recording_file(json_text))
  list.map(file.entries, fn(entry) { entry.response.status })
}
```

For the file of the 429 above, `recorded_statuses` returns `Ok([429])`. `recording.encode_recording_file(file)` turns a `RecordingFile` back into JSON, and `storage.save_recordings(directory, recordings, key)` writes several recordings at once, one file each.

## Test your code

The usual setup: commit the recordings to your repository, and start a playback recorder on their directory in your tests. This package has one such file, `test/fixtures/api/GET_localhost__text_7646ad.json`, which answers `GET http://localhost:9876/text` with `Recorded text from the fixture`. Here's a test of `fetch_text` that plays it back. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test fetch_text with a committed recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_recording_testing.gleam#L6-L37"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{host, port, recorder as with_recorder, scheme}
import dream_http_client/recorder
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import snippets/guide_recording_client.{fetch_text, start_recorder}

pub fn tests() -> TestSuite {
  describe("fetch_text", [
    it("reads the recorded text", fn() {
      // Arrange
      let assert Ok(playback) =
        start_recorder(recorder.Playback, "test/fixtures/api")
      let api =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(9876)
        |> with_recorder(playback)

      // Act
      let text = fetch_text(api)

      // Assert
      text
      |> should
      |> be_equal(Ok("Recorded text from the fixture"))
      |> or_fail_with("Expected the text of the recording")
    }),
  ])
}
```

The test passes whether or not a server runs on port 9876, and the text it checks only exists in the recording, so it can't pass by accident against a live server.

To refresh the recordings, run the same code once with `start_recorder(recorder.Record, ...)` against the real API, then switch back to `recorder.Playback` and commit the changes. You don't need to delete the old files first: the record run replaces the file of each request it records, and a request with the same response gives the same file.

## Common pitfalls

**A test that only passed because of the network.** *Symptom:* after an upgrade, a test fails with `NoRecording`. *Fix:* in playback mode, a request with no recording isn't sent any more. Before 6.0.0, it went to the live service. Record the missing request, or write its recording by hand.

**Secrets in committed recordings.** *Symptom:* an API token or a session cookie shows up in a recording file in your repository. *Fix:* record with a request transformer and a response transformer that remove them. See [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md).

**A recording directory that can't be written.** *Symptom:* in record mode, `send` returns `Error(RequestError(Unexpected("Failed to save recording: ...")))` although the server answered. *Fix:* the recorder could not write the file, and the call returns that error, so no test goes on with a recording that is not there. Check that the directory, or its parent, exists as a directory and that the program may write to it.

**Adding a recording to a playback recorder.** *Symptom:* `add_recording` returns, but playback still fails with `NoRecording`. *Fix:* `add_recording` does nothing in playback mode. Save the file with `storage.save_recording_immediately` before you start the playback recorder.

**A recording made with a different port.** *Symptom:* `NoRecording` although a file for the path exists. *Fix:* the default key compares the whole URL, port included. Record against the same scheme, host and port that the tests use, or use a key that ignores the URL parts that change.

## Where to go next

- [Matching requests and hiding secrets in recordings](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/request-matching-and-scrubbing.md): choose what makes two requests the same, and keep tokens out of your files.
- [Streaming a response](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/streaming.md#test-your-streaming-code): test stream code against a recording that splits a line across chunks.
- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): the base-request pattern that makes recordings easy.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/recorder.html): `recorder`, `recording` and `storage`.
