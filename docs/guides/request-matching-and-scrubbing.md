# Matching requests and hiding secrets in recordings

Recordings go into your repository, so two questions come up as soon as you use them for real. Which recording answers which request? Two searches to the same URL with different bodies need two answers, but a request whose token changed since you recorded it should still find its recording. And what ends up in the files? A bearer token or a session cookie in a committed recording is a leaked secret. This guide answers both: how the recorder matches a request to a recording, how to change that, and how to remove secrets before anything is saved.

## Table of Contents

- [What you'll build](#what-youll-build)
- [Before you start](#before-you-start)
- [Which tool to reach for](#which-tool-to-reach-for)
- [Step 1: See the key of a request](#step-1-see-the-key-of-a-request)
- [Step 2: Match on the body too](#step-2-match-on-the-body-too)
- [Step 3: Remove the token from requests](#step-3-remove-the-token-from-requests)
- [Step 4: Remove cookies from responses](#step-4-remove-cookies-from-responses)
- [When two recordings match](#when-two-recordings-match)
- [Test your code](#test-your-code)
- [Common pitfalls](#common-pitfalls)
- [Where to go next](#where-to-go-next)

## What you'll build

In this guide you'll:

- See the key the recorder computes for a request.
- Record two POST requests to one URL, with different bodies, and play each one back.
- Record through a recorder that removes the `Authorization` header, and play back with a different token.
- Keep a `set-cookie` header out of the files, while your code still gets it live.
- Understand the error for two recordings with one key.
- Test that no token reaches your recordings.

## Before you start

You need the package:

```sh
gleam add dream_http_client
```

This guide builds on [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md), which shows how to record and play back. The examples record from [dream_mock_server](https://github.com/TrustBound/dream_mock_server) on `localhost:9876`, whose `/post` endpoint echoes the body it received, and from a small test server that answers with a `set-cookie: session=abc123` header.

## Which tool to reach for

| Your situation | Use | Why |
|:---|:---|:---|
| Requests to one URL differ only in their body, such as search or GraphQL | `key(matching.request_key(..., body: True))` | The body becomes part of the key, so each body gets its own recording. |
| Requests differ in a header that changes every run, such as a token or a request ID | `request_transformer` that removes it | The header is gone before the key is computed and before the file is saved. |
| Responses hold secrets, such as cookies or tokens | `response_transformer` that removes them | It changes the response before the recorder saves it. Your code still gets the live response. |
| You need full control over what counts as the same request | Your own `MatchKey` function | A `MatchKey` is `fn(RecordedRequest) -> String`. |

## Step 1: See the key of a request

The recorder files and finds each recording under a key: a string made from the parts of the request you choose. `matching.request_key` builds the function that makes it. For a POST to `http://localhost:9876/search` with the body `milk` and an `Authorization` header:

### Two keys of one request <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_matching_keys.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
request_key(method: True, url: True, headers: False, body: False)   -> "POSThttp://localhost:9876/search"
request_key(method: True, url: True, headers: False, body: True)    -> "POSThttp://localhost:9876/searchmilk"
```

The first one is the default, and it's what a recorder uses when you don't set a key. Two requests match when their keys are equal, so with the default key, the body and the headers make no difference. The URL part holds the scheme, the host, the port, the path and the query.

## Step 2: Match on the body too

A search API that takes its terms in a POST body needs the body in the key. Otherwise every search finds the same recording. Here's a recorder for it:

### Match requests by their body as well <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_matching_body_key.gleam#L6-L23"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

pub fn start_search_recorder(
  recorder_mode: recorder.Mode,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(recorder_mode)
  |> key(matching.request_key(
    method: True,
    url: True,
    headers: False,
    body: True,
  ))
  |> start()
}
```

Record a search for `milk` and one for `eggs` through it, stop it, and start it again in playback mode on the same directory. Each body gets its own answer back:

### Two searches played back with a body key <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_matching_body_key.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
search "milk" -> {"method":"POST","url":"/post","data":"milk"}
search "eggs" -> {"method":"POST","url":"/post","data":"eggs"}
```

Use the same key to record and to play back. A recording is filed under the key of the recorder that loads it, so a playback recorder with a different key reads the same files differently, as the [next section](#when-two-recordings-match) shows.

## Step 3: Remove the token from requests

A request transformer is a function from `RecordedRequest` to `RecordedRequest`. The recorder runs it on every request before it computes the key and before it saves, in every mode. Remove the `Authorization` header there, and two good things happen: the token never reaches a file, and a request with a different token still matches the recording.

Here's a recorder that does it, together with the response side from Step 4:

### Remove the token and the cookies <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_matching_scrub.gleam#L7-L66"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/recorder.{
  type Recorder, directory, mode, request_transformer, response_transformer,
  start,
}
import dream_http_client/recording.{
  type RecordedRequest, type RecordedResponse, BlockingResponse, RecordedRequest,
  StreamingResponse,
}
import gleam/list
import gleam/string

pub fn start_scrubbing_recorder(
  recorder_mode: recorder.Mode,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(recorder_mode)
  |> request_transformer(drop_authorization)
  |> response_transformer(drop_cookies)
  |> start()
}

/// Runs before the recorder computes the key and before it saves, in
/// every mode, so a request with another token still matches.
pub fn drop_authorization(request: RecordedRequest) -> RecordedRequest {
  RecordedRequest(
    ..request,
    headers: list.filter(request.headers, fn(header) {
      string.lowercase(header.0) != "authorization"
    }),
  )
}

/// Runs only in record mode, before the recorder saves the response.
pub fn drop_cookies(
  _request: RecordedRequest,
  response: RecordedResponse,
) -> RecordedResponse {
  case response {
    BlockingResponse(status: status, headers: headers, body: body) ->
      BlockingResponse(
        status: status,
        headers: without_cookies(headers),
        body: body,
      )
    StreamingResponse(status: status, headers: headers, chunks: chunks) ->
      StreamingResponse(
        status: status,
        headers: without_cookies(headers),
        chunks: chunks,
      )
  }
}

fn without_cookies(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) { string.lowercase(header.0) != "set-cookie" })
}
```

Record a request with `Authorization: Bearer test-token-123` through it, then play back with `Bearer other-token`:

### A request with its token removed <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_matching_request_scrub.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
the saved file contains "test-token-123"         -> no
playback with Authorization: Bearer other-token  -> Ok(response)  (status 200, body "ok")
```

The comparison in `drop_authorization` uses `string.lowercase`, because the header name in a `RecordedRequest` is the name you gave `add_header`, in your own case.

## Step 4: Remove cookies from responses

A response transformer gets the request and the response, and returns the response to save. `drop_cookies` above removes every `set-cookie` header, from blocking and streaming responses alike. It runs only in record mode, and only on what's saved:

### A response with its cookie removed <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_matching_response_scrub.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
the response your code gets while recording   -> headers set-cookie: session=abc123, content-length: 2
the saved file contains "session=abc123"      -> no
playback of the recording                       -> headers content-length: 2, body "ok"
```

Because it runs only when recording, a response transformer doesn't change a file that's already there. A recording that you wrote by hand with a `set-cookie` header plays back with that header, through the same recorder.

## When two recordings match

When the key of a request matches more than one recording, playback compares their responses. If they're all equal, it uses one of them. If they differ, the request fails:

### Two different responses for one key <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/outputs/guide_matching_ambiguous.txt"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```text
Error(RequestError(Unexpected("Ambiguous recording match for key: POSThttp://localhost:9876/post (2 recordings)")))
```

That's what happens when you record the `milk` and `eggs` searches of Step 2 with a body key, and then play them back with the default key, which ignores the body. The fix is a key that tells the requests apart, or a transformer that removes the part that differs by accident. The error is deliberate: picking one of two different answers at random would make your tests flaky.

## Test your code

The test worth having is the one that keeps secrets out of your repository: record through your recorder, load what it saved, and check it. `storage.load_recordings` reads every recording in a directory, so the test doesn't depend on file names. Here's one for the scrubbing recorder. It uses [dream_test](https://hexdocs.pm/dream_test), set up as in [Getting started](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/getting-started.md#test-your-code):

### Test that recordings hold no token <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/guide_matching_testing.gleam#L6-L59"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>

```gleam
import dream_http_client/client.{
  add_header, host, path, port, recorder as with_recorder, scheme, send,
}
import dream_http_client/recorder
import dream_http_client/recording.{type Recording}
import dream_http_client/storage
import dream_mock_server/server
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/http
import gleam/list
import gleam/result
import simplifile
import snippets/guide_matching_scrub.{start_scrubbing_recorder}

pub fn tests() -> TestSuite {
  describe("scrubbing recorder", [
    it("saves the request without its Authorization header", fn() {
      // Arrange
      let recordings = "build/guide_matching_recordings"
      let _deleted = simplifile.delete(recordings)
      let assert Ok(mock) = server.start(19_997)
      let assert Ok(scrubbing) =
        start_scrubbing_recorder(recorder.Record, recordings)

      // Act
      let _response =
        client.new()
        |> scheme(http.Http)
        |> host("localhost")
        |> port(19_997)
        |> path("/text")
        |> add_header("Authorization", "Bearer test-token-123")
        |> with_recorder(scrubbing)
        |> send()
      let assert Ok(Nil) = recorder.stop(scrubbing)
      server.stop(mock)
      let saved_headers =
        storage.load_recordings(recordings)
        |> result.map(list.map(_, request_headers))

      // Assert
      saved_headers
      |> should
      |> be_equal(Ok([[]]))
      |> or_fail_with("Expected one recording with no headers")
    }),
  ])
}

fn request_headers(saved: Recording) -> List(#(String, String)) {
  saved.request.headers
}
```

The test deletes the directory first, so it checks only what this run recorded, and it stops the recorder before it reads, so every file is on disk.

For lookups in a test, `recorder.find_recording(recorder, request)` tells you whether a playback recorder has a recording for a request, and `recorder.get_recordings(recorder)` lists what it loaded.

## Common pitfalls

**A header name in a different case.** *Symptom:* the token is still in the file, although your transformer removes `authorization`. *Fix:* the header keeps the case you gave `add_header`. Compare names in lower case, as `drop_authorization` does.

**Recording and playing back with different keys.** *Symptom:* `NoRecording` or an ambiguous match for requests you just recorded. *Fix:* use the same `key` and the same request transformer for the record and the playback recorder. Build both from one function, as `start_search_recorder` and `start_scrubbing_recorder` do.

**Expecting a response transformer to clean old files.** *Symptom:* a cookie is still in a recording after you added `drop_cookies`. *Fix:* it runs only when recording. Record the file again, or edit it.

**Volatile parts in the key.** *Symptom:* every run records new files, and playback can't find any of them. *Fix:* a timestamp or a random ID in the URL or the body changes the key every time. Remove it with a request transformer, or leave that part out of the key.

## Where to go next

- [Testing with recorded responses](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/recording-and-playback.md): record, play back, streams, and recordings written by hand.
- [Sending data to an API](https://github.com/TrustBound/dream_http_client/blob/main/docs/guides/sending-data.md#step-4-send-a-token-with-every-request): where the token in your requests comes from.
- [API reference on HexDocs](https://hexdocs.pm/dream_http_client/dream_http_client/matching.html): `matching.request_key`, and the `recorder` and `recording` modules.
