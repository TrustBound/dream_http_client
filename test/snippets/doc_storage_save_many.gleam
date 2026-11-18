import dream_http_client/matching
import dream_http_client/recording
import dream_http_client/storage

pub fn save_all(
  mocks_directory: String,
  recordings: List(recording.Recording),
) -> String {
  let key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)

  case storage.save_recordings(mocks_directory, recordings, key_fn) {
    Ok(_) -> "Saved recordings successfully"
    Error(reason) -> "Failed to save: " <> reason
  }
}
