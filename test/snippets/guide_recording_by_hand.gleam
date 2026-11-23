//// Guide: Testing with recorded responses, step 5
////
//// Writes a recording without a server: a response that is hard to get
//// from the real API.

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
