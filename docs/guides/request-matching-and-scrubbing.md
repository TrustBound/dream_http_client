# Request matching and scrubbing

This guide shows how the recorder matches a request to a recording, how to remove secrets from requests and responses before they are saved, and what happens when more than one recording matches.

## Request matching

A request key function decides which parts of a request must be the same for a request to match a recording. Build one from include and exclude flags with `matching.request_key()`, and give it to the recorder with `key()`.

### Request Matching <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/matching_config.gleam#L6-L29"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

// Build a request key function from include/exclude flags
pub fn method_and_url_key() -> matching.MatchKey {
  matching.request_key(
    method: True,
    url: True,
    // Ignore auth tokens, timestamps
    headers: False,
    // Ignore request IDs in body
    body: False,
  )
}

pub fn start_playback(
  recordings_directory: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings_directory)
  |> mode("playback")
  |> key(method_and_url_key())
  |> start()
}
```

## Scrubbing secrets with transformers

If your requests contain secrets (such as `Authorization` headers) or volatile fields (timestamps, request IDs), you can attach a transformer to **normalize** requests _before_ the recorder computes the key and before it saves anything.

### Scrub the request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_transformer.gleam#L6-L58"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{
  type Recorder, directory, key, mode, request_transformer, start,
}
import dream_http_client/recording
import gleam/list

pub fn scrub_auth_and_body(
  request: recording.RecordedRequest,
) -> recording.RecordedRequest {
  let recording.RecordedRequest(
    method,
    scheme,
    host,
    port,
    path,
    query,
    headers,
    _body,
  ) = request

  let scrubbed_headers = list.filter(headers, is_not_authorization_header)

  recording.RecordedRequest(
    method: method,
    scheme: scheme,
    host: host,
    port: port,
    path: path,
    query: query,
    headers: scrubbed_headers,
    body: <<>>,
  )
}

fn is_not_authorization_header(header: #(String, String)) -> Bool {
  header.0 != "Authorization"
}

// Requests recorded through this recorder have their secrets scrubbed
pub fn start_scrubbing_recorder(
  recordings_directory: String,
) -> Result(Recorder, String) {
  let request_key_fn =
    matching.request_key(method: True, url: True, headers: True, body: True)

  recorder.new()
  |> directory(recordings_directory)
  |> mode("record")
  |> key(request_key_fn)
  |> request_transformer(scrub_auth_and_body)
  |> start()
}
```

If you must scrub **responses** (cookies, tokens, personal data) before the recorder writes fixtures to disk, use a response transformer. It runs **only in record mode**.

### Scrub the response <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_response_transformer.gleam#L6-L45"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/recorder.{
  type Recorder, directory, mode, response_transformer, start,
}
import dream_http_client/recording
import gleam/list

pub fn scrub_response(
  _request: recording.RecordedRequest,
  response: recording.RecordedResponse,
) -> recording.RecordedResponse {
  case response {
    recording.BlockingResponse(status, headers, _body) ->
      recording.BlockingResponse(
        status: status,
        headers: list.filter(headers, is_not_set_cookie),
        body: <<>>,
      )

    recording.StreamingResponse(status, headers, chunks) ->
      recording.StreamingResponse(
        status: status,
        headers: list.filter(headers, is_not_set_cookie),
        chunks: chunks,
      )
  }
}

fn is_not_set_cookie(header: #(String, String)) -> Bool {
  header.0 != "set-cookie"
}

pub fn start_scrubbing_recorder(
  recordings_directory: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings_directory)
  |> mode("record")
  |> response_transformer(scrub_response)
  |> start()
}
```

## Ambiguous matches (key collisions)

Playback **returns an error** if more than one recording matches the same request key. This is intentional: it makes you refine your key function (or add a transformer) so that each request maps to exactly one recording.

### Playback with a method and URL key <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/recording_ambiguous_match.gleam#L6-L22"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

// A lookup through this recorder returns Error("Ambiguous recording match ...")
// when more than one recording matches the request key
pub fn start_playback(
  recordings_directory: String,
) -> Result(Recorder, String) {
  let request_key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)

  recorder.new()
  |> directory(recordings_directory)
  |> mode("playback")
  |> key(request_key_fn)
  |> start()
}
```

## More examples

- [Custom request keys](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/matching_config.gleam): configure request matching
- [Request transformers](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_transformer.gleam): scrub secrets before keying and persistence
- [Response transformers](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_response_transformer.gleam): scrub secrets from recorded responses
- [Ambiguous match errors](https://github.com/TrustBound/dream_http_client/blob/main/test/snippets/recording_ambiguous_match.gleam): key collision behavior

## See also

- [Recording and playback](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record requests and play them back
- [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md): install the package and choose an execution mode
- [README](https://github.com/TrustBound/dream_http_client/blob/main/README.md)
