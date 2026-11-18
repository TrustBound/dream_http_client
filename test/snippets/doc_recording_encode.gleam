import dream_http_client/recording
import gleam/json

pub fn to_json_string(entries: List(recording.Recording)) -> String {
  let file = recording.RecordingFile(version: "1.0", entries: entries)
  let json_value = recording.encode_recording_file(file)
  // Now write the string to disk
  json.to_string(json_value)
}
