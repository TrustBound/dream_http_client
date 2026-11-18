//// Scratch directories for tests that write recordings to disk.
////
//// Every path is under `root`. The test entry point deletes `root` before
//// the run, so each run starts empty and the paths stay the same between
//// runs.

/// The directory that holds every scratch directory.
pub const root = "build/test_tmp"

/// The scratch directory for one test. Give every test its own `label`.
pub fn path(label: String) -> String {
  root <> "/" <> label
}
