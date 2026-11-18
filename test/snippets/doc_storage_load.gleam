import dream_http_client/storage
import gleam/int
import gleam/list

pub fn describe_recordings(mocks_directory: String) -> String {
  // Load recordings for inspection
  case storage.load_recordings(mocks_directory) {
    Ok(recordings) ->
      "Loaded " <> int.to_string(list.length(recordings)) <> " recordings"
    Error(reason) -> "Failed to load: " <> reason
  }
}
