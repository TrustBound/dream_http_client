//// Keep the log output of the client while a function runs, so a test can
//// assert it. See `log_capture_ffi.erl`.

/// Run `run`, then wait until `count` log lines of the client arrived, or
/// until `timeout_ms` passed, and return the value of `run` with the log
/// lines, such as `"warning: [dream_http] connection down: pid=<pid> ..."`.
/// The lines come from other processes, often after `run` returned, so the
/// wait is for the lines. With a `count` of 0, it waits the whole timeout.
@external(erlang, "log_capture_ffi", "capture")
pub fn capture(
  run: fn() -> value,
  count: Int,
  timeout_ms: Int,
) -> #(value, List(String))
