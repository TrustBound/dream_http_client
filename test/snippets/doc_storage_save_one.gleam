import dream_http_client/matching
import dream_http_client/recording
import dream_http_client/storage

pub fn save_one(
  mocks_directory: String,
  recorded: recording.Recording,
) -> String {
  // Compute the key with the same key policy you use for playback
  let key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)
  let key = key_fn(recorded.request)

  case storage.save_recording_immediately(mocks_directory, recorded, key) {
    Ok(_) -> "Saved recording"
    Error(reason) -> "Failed to save: " <> reason
  }
}
