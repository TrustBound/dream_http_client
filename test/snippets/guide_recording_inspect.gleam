//// Guide: Testing with recorded responses, step 5
////
//// Reads the statuses of the recordings in one file, for a script that
//// checks the recordings of a repository.

import dream_http_client/recording
import gleam/list
import gleam/result
import simplifile

pub fn recorded_statuses(file_path: String) -> Result(List(Int), String) {
  use json_text <- result.try(
    simplifile.read(file_path) |> result.map_error(simplifile.describe_error),
  )
  use file <- result.map(recording.decode_recording_file(json_text))
  list.map(file.entries, fn(entry) { entry.response.status })
}
