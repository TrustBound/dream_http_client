import dream_http_client/recording
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn count_entries(path: String) -> Result(String, String) {
  // Read JSON from one recording file
  use json_content <- result.try(
    simplifile.read(path) |> result.map_error(string.inspect),
  )

  // Decode it to a RecordingFile (each file holds one entry)
  case recording.decode_recording_file(json_content) {
    Ok(file) ->
      Ok(
        "Loaded " <> int.to_string(list.length(file.entries)) <> " recording(s)",
      )
    Error(reason) -> Error("Failed to decode: " <> reason)
  }
}
