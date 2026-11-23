//// Guide: Testing with recorded responses, steps 1 and 2
////
//// Records fetch_text once against the server, then plays it back.

import dream_http_client/client.{type ClientRequest, recorder as with_recorder}
import dream_http_client/recorder
import gleam/result
import snippets/guide_recording_client.{fetch_text, start_recorder}

pub fn record_text(
  api: ClientRequest,
  recordings: String,
) -> Result(String, String) {
  use recording <- result.try(start_recorder("record", recordings))
  let text = fetch_text(api |> with_recorder(recording))
  // Returns when the recordings that this process handed over are on disk
  use Nil <- result.try(recorder.stop(recording))
  text
}

pub fn play_back_text(
  api: ClientRequest,
  recordings: String,
) -> Result(String, String) {
  use playback <- result.try(start_recorder("playback", recordings))
  fetch_text(api |> with_recorder(playback))
}
