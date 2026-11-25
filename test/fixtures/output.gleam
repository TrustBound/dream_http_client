//// Keep what a function prints, so a test can assert the exact output.

/// Run `run` and return its value with the text that it printed. Output of
/// the processes that `run` starts is kept too, until `run` returns.
@external(erlang, "output_capture_ffi", "capture")
pub fn capture(run: fn() -> value) -> #(value, String)
