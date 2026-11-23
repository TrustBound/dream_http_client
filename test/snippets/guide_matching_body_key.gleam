//// Guide: Matching requests and hiding secrets in recordings, step 2
////
//// A recorder for an API where the body says what the request asks for,
//// so two requests to the same URL need two recordings.

import dream_http_client/matching
import dream_http_client/recorder.{type Recorder, directory, key, mode, start}

pub fn start_search_recorder(
  mode_name: String,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(mode_name)
  |> key(matching.request_key(
    method: True,
    url: True,
    headers: False,
    body: True,
  ))
  |> start()
}
