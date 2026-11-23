//// Keep the log output of the client while a function runs, so a test can
//// assert it. See `log_capture_ffi.erl`.

/// Run `run`, wait `wait_ms` for log events that arrive late, and return the
/// value of `run` with the log lines of the client, such as
/// `"warning: [dream_http] connection down: pid=<pid> ..."`.
@external(erlang, "log_capture_ffi", "capture")
pub fn capture(run: fn() -> value, wait_ms: Int) -> #(value, List(String))
