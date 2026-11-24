//// File I/O for recordings
////
//// Handles loading and saving recording files to/from the filesystem.

import dream_http_client/matching
import dream_http_client/recording
import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Load recordings from a directory
///
/// Scans the directory for all `.json` files and loads them as individual recordings.
/// This function is used internally by the recorder when starting in Playback mode, but
/// can also be called directly to inspect or manipulate recordings.
///
/// ## Parameters
///
/// - `directory`: The directory containing individual recording files
///
/// ## Returns
///
/// - `Ok(List(Recording))`: Successfully loaded recordings (empty list if directory doesn't exist)
/// - `Error(String)`: Error message if directory exists but files cannot be read or decoded
///
/// ## Examples
///
/// ### Load recordings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_storage_load.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/storage
/// import gleam/int
/// import gleam/list
///
/// pub fn describe_recordings(mocks_directory: String) -> String {
///   // Load recordings for inspection
///   case storage.load_recordings(mocks_directory) {
///     Ok(recordings) ->
///       "Loaded " <> int.to_string(list.length(recordings)) <> " recordings"
///     Error(reason) -> "Failed to load: " <> reason
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Returns an empty list (not an error) if the directory doesn't exist
/// - This is the expected behavior for Playback mode when no recordings have been created yet
/// - Each file contains a single recording in the versioned JSON format
pub fn load_recordings(
  directory: String,
) -> Result(List(recording.Recording), String) {
  load_recording_files(directory)
  |> result.map(list.map(_, fn(file) { file.1 }))
}

/// Load every recording of a directory with the path of its file.
///
/// The recorder uses it in Record mode to find the files of a request
/// that it records again. The errors are those of `load_recordings`.
@internal
pub fn load_recording_files(
  directory: String,
) -> Result(List(#(String, recording.Recording)), String) {
  // List all .json files in directory
  case simplifile.read_directory(directory) {
    Ok(files) -> {
      // Filter for .json files
      let json_files =
        list.filter(files, fn(file) { string.ends_with(file, ".json") })

      // Load each file
      json_files
      |> list.try_map(fn(filename) {
        let file_path = directory <> "/" <> filename
        case simplifile.read(file_path) {
          Ok(content) -> {
            case recording.decode_recording_file(content) {
              Ok(file) -> {
                // Extract first entry (should only be one per file)
                case list.first(file.entries) {
                  Ok(entry) -> Ok(#(file_path, entry))
                  Error(_) ->
                    Error("Recording file contains no entries: " <> file_path)
                }
              }
              Error(reason) ->
                Error("Failed to decode " <> file_path <> ": " <> reason)
            }
          }
          Error(read_error) ->
            Error(
              "Failed to read "
              <> file_path
              <> ": "
              <> string.inspect(read_error),
            )
        }
      })
    }
    Error(simplifile.Enoent) -> {
      // Directory doesn't exist - return empty list (not an error)
      Ok([])
    }
    Error(read_error) -> {
      Error(
        "Failed to read directory "
        <> directory
        <> ": "
        <> string.inspect(read_error),
      )
    }
  }
}

/// Remove a recording file. A file that is already gone is not an error,
/// because another recorder can remove it first.
@internal
pub fn remove_recording_file(file_path: String) -> Result(Nil, String) {
  case simplifile.delete(file_path) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(delete_error) ->
      Error(
        "Failed to remove recording file "
        <> file_path
        <> ": "
        <> string.inspect(delete_error),
      )
  }
}

/// Save a single recording immediately to its own file
///
/// Writes a single recording to an individual file.
///
/// The file name has human-readable parts (method, host and path) and a
/// hash of the **match key**. The name does not depend on the response, so
/// a request keeps its file name, and a new recording of the same key
/// replaces the file.
///
/// ## Parameters
///
/// - `directory`: The directory where the recording file will be written
/// - `rec`: The recording to save
/// - `key`: The match key string for this request (should match the recorder's key function)
///
/// ## Returns
///
/// - `Ok(Nil)`: Successfully saved the recording
/// - `Error(String)`: Error message if directory creation or file write fails
///
/// ## Examples
///
/// ### Save one recording <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_storage_save_one.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recording
/// import dream_http_client/storage
///
/// pub fn save_one(
///   mocks_directory: String,
///   recorded: recording.Recording,
/// ) -> String {
///   // Compute the key with the same key policy you use for playback
///   let key_fn =
///     matching.request_key(method: True, url: True, headers: False, body: False)
///   let key = key_fn(recorded.request)
///
///   case storage.save_recording_immediately(mocks_directory, recorded, key) {
///     Ok(_) -> "Saved recording"
///     Error(reason) -> "Failed to save: " <> reason
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Each recording is saved to its own file for O(1) write performance
/// - File names have human-readable parts (method, host, path) and a hash of the key
/// - A file with the same name is replaced
/// - Concurrent tests can record safely without file contention
pub fn save_recording_immediately(
  directory: String,
  rec: recording.Recording,
  key: String,
) -> Result(Nil, String) {
  // Create directory if it doesn't exist
  // An existing directory is fine: create_directory_all returns Ok for it.
  simplifile.create_directory_all(directory)
  |> result.map_error(fn(directory_error) {
    "Failed to create directory "
    <> directory
    <> ": "
    <> string.inspect(directory_error)
  })
  |> result.try(fn(_) {
    // Create recording file with single entry
    let recording_file = recording.RecordingFile(version: "1.0", entries: [rec])

    // Encode to JSON
    let json_value = recording.encode_recording_file(recording_file)
    let json_string = json.to_string(json_value)

    // The name comes from the request and its key only, so a request keeps
    // its file name when its response changes.
    let filename = build_filename(rec.request, key)
    let file_path = directory <> "/" <> filename

    // Write to file atomically so readers never see partial content
    case atomic_write(file_path, json_string) {
      Ok(Nil) -> Ok(Nil)
      Error(write_error) -> {
        Error(
          "Failed to write recording file "
          <> file_path
          <> ": "
          <> string.inspect(write_error),
        )
      }
    }
  })
}

/// Save multiple recordings to individual files
///
/// Writes each recording to its own file in the directory. Creates the directory if it
/// doesn't exist. Each file is named based on the request signature for easy identification.
///
/// ## Parameters
///
/// - `directory`: The directory where recording files will be written
/// - `recordings`: List of recordings to save
/// - `key_fn`: Match key function used to compute each recording's key string
///
/// ## Returns
///
/// - `Ok(Nil)`: Successfully saved all recordings
/// - `Error(String)`: Error message if directory creation or file write fails
///
/// ## Examples
///
/// ### Save many recordings <a href="https://github.com/TrustBound/dream_http_client/blob/6.0.0/test/snippets/doc_storage_save_many.gleam"><img align="right" alt="Tested snippet" src="https://img.shields.io/badge/%F0%9F%A7%AA_tested-snippet-lightgreen.svg?style=flat-square"></a>
///
/// ```gleam
/// import dream_http_client/matching
/// import dream_http_client/recording
/// import dream_http_client/storage
///
/// pub fn save_all(
///   mocks_directory: String,
///   recordings: List(recording.Recording),
/// ) -> String {
///   let key_fn =
///     matching.request_key(method: True, url: True, headers: False, body: False)
///
///   case storage.save_recordings(mocks_directory, recordings, key_fn) {
///     Ok(_) -> "Saved recordings successfully"
///     Error(reason) -> "Failed to save: " <> reason
///   }
/// }
/// ```
///
/// ## Notes
///
/// - Directory is created automatically if it doesn't exist
/// - Each recording is saved to its own file (no file contention)
/// - Existing files with the same name are overwritten, so of two recordings
///   with the same key, the last one stays
pub fn save_recordings(
  directory: String,
  recordings: List(recording.Recording),
  key_fn: matching.MatchKey,
) -> Result(Nil, String) {
  // Create directory if it doesn't exist
  // An existing directory is fine: create_directory_all returns Ok for it.
  simplifile.create_directory_all(directory)
  |> result.map_error(fn(directory_error) {
    "Failed to create directory "
    <> directory
    <> ": "
    <> string.inspect(directory_error)
  })
  |> result.try(fn(_) {
    // Save each recording to its own file
    recordings
    |> list.try_each(fn(rec) {
      let key = key_fn(rec.request)
      save_recording_immediately(directory, rec, key)
    })
  })
}

/// Build the file name of a recording from its request and its key
///
/// Creates a file name with the format:
///
/// `{method}_{host}_{path}_{key_hash}.json`
///
/// - `key_hash` is the first 16 hex characters of the SHA-256 of the match
///   key, so one key always gets the same name
///
/// ## Examples
///
/// - `GET_localhost__text_7646ad0d38469745.json`
fn build_filename(request: recording.RecordedRequest, key: String) -> String {
  // Build human-readable part from method + host + path
  let method_part = sanitize_for_filename(method_to_string(request.method))
  let host_part = sanitize_for_filename(request.host)
  let path_part =
    request.path
    |> string.replace("/", "_")
    |> sanitize_for_filename()
    |> truncate_string(50)

  // 16 hex characters (64 bits) keep two keys with the same method, host
  // and path apart.
  let key_hash = string.slice(generate_hash(key), 0, 16)

  // Combine parts
  method_part
  <> "_"
  <> host_part
  <> "_"
  <> path_part
  <> "_"
  <> key_hash
  <> ".json"
}

fn method_to_string(method: http.Method) -> String {
  case method {
    http.Get -> "GET"
    http.Post -> "POST"
    http.Put -> "PUT"
    http.Delete -> "DELETE"
    http.Patch -> "PATCH"
    http.Head -> "HEAD"
    http.Options -> "OPTIONS"
    http.Trace -> "TRACE"
    http.Connect -> "CONNECT"
    http.Other(s) -> string.uppercase(s)
  }
}

/// Sanitize a string to be safe for use in filenames
///
/// Replaces characters that are problematic in filenames with underscores.
/// Allows alphanumeric, hyphens, periods, and underscores.
fn sanitize_for_filename(input: String) -> String {
  input
  |> string.to_graphemes()
  |> list.map(fn(char) {
    case char {
      "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f"
      | "g"
      | "h"
      | "i"
      | "j"
      | "k"
      | "l"
      | "m"
      | "n"
      | "o"
      | "p"
      | "q"
      | "r"
      | "s"
      | "t"
      | "u"
      | "v"
      | "w"
      | "x"
      | "y"
      | "z" -> char
      "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F"
      | "G"
      | "H"
      | "I"
      | "J"
      | "K"
      | "L"
      | "M"
      | "N"
      | "O"
      | "P"
      | "Q"
      | "R"
      | "S"
      | "T"
      | "U"
      | "V"
      | "W"
      | "X"
      | "Y"
      | "Z" -> char
      "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> char
      "-" | "." | "_" -> char
      _ -> "_"
    }
  })
  |> string.join("")
}

/// Truncate a string to a maximum length
fn truncate_string(input: String, max_length: Int) -> String {
  case string.length(input) > max_length {
    True -> string.slice(input, 0, max_length)
    False -> input
  }
}

/// Generate a hash from a string
fn generate_hash(input: String) -> String {
  let bits = bit_array.from_string(input)
  let hash_bits = crypto.hash(crypto.Sha256, bits)
  bit_array.base16_encode(hash_bits)
  |> string.lowercase()
}

@external(erlang, "dream_http_client_fs_shim", "atomic_write")
fn atomic_write(file_path: String, content: String) -> Result(Nil, String)
