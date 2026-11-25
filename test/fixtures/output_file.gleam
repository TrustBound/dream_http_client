//// The output files that the guides show. Each `text` block of a guide is
//// a copy of a file in `test/outputs/`, and a test compares that file with
//// the real output of the code. So the block, the file and the output are
//// one thing: a change of the code fails the test, and a change of the
//// block fails the docs check.

import gleam/result
import gleam/string
import simplifile

/// The content of `test/outputs/<name>.txt`, or `""` when it can't be read.
pub fn read(name: String) -> String {
  simplifile.read("test/outputs/" <> name <> ".txt")
  |> result.unwrap("")
}

/// The lines as an output file holds them: a line break after each.
pub fn lines(lines: List(String)) -> String {
  string.join(lines, "\n") <> "\n"
}
