//// Every log line of the client goes through `dream_http_client_log`, so
//// the `log_level` setting applies to it. A log call in another module of
//// `src/` would not follow the setting, so this test finds none.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}
import gleam/int
import gleam/list
import gleam/string
import simplifile

const source_directory = "src/dream_http_client"

/// The one module that may call the OTP logger.
const log_module = "dream_http_client_log.erl"

/// Calls that write a log line or print to the terminal.
const log_calls = [
  "logger:", "error_logger:", "io:format", "io:put_chars", "io.print",
  "io.println", "io.debug",
]

pub fn tests() -> TestSuite {
  describe("dream_http_client logs in one place", [
    it(
      "no module of src/ other than dream_http_client_log writes a log line",
      fn() {
        // Arrange
        let files = source_files()

        // Act
        let log_lines = list.flat_map(files, log_lines_of)

        // Assert
        log_lines
        |> should
        |> be_equal([])
        |> or_fail_with("Every log call goes through dream_http_client_log")
      },
    ),
  ])
}

fn source_files() -> List(String) {
  case simplifile.read_directory(source_directory) {
    Ok(names) ->
      names
      |> list.filter(fn(name) { name != log_module })
      |> list.sort(string.compare)
    Error(error) -> [
      "cannot read " <> source_directory <> ": " <> string.inspect(error),
    ]
  }
}

/// Each code line of the file that calls a log function, as
/// `"file:line: text"`. Comment lines and doc comments do not count.
fn log_lines_of(name: String) -> List(String) {
  case simplifile.read(source_directory <> "/" <> name) {
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.index_map(fn(line, index) { #(index + 1, line) })
      |> list.filter(fn(numbered) { is_log_call(numbered.1) })
      |> list.map(fn(numbered) {
        name
        <> ":"
        <> int.to_string(numbered.0)
        <> ": "
        <> string.trim(numbered.1)
      })
    Error(error) -> [name <> ": " <> string.inspect(error)]
  }
}

fn is_log_call(line: String) -> Bool {
  let code = string.trim_start(line)
  let is_comment =
    string.starts_with(code, "//") || string.starts_with(code, "%")
  !is_comment && list.any(log_calls, fn(call) { string.contains(code, call) })
}
