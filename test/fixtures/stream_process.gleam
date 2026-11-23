//// Find the process that runs a stream of `client.stream_to`, for the tests
//// that check that the stream process stops, and kill the owner process of
//// a `client.stream_yielder` stream.

import dream_http_client/client
import gleam/erlang/process

/// The process that runs the stream of `request_id`.
///
/// `RequestId` is opaque. On the BEAM it is the record
/// `{request_id, StreamPid}`, so this reads its second element.
pub fn of(request_id: client.RequestId) -> process.Pid {
  record_element(2, request_id)
}

@external(erlang, "erlang", "element")
fn record_element(index: Int, record: client.RequestId) -> process.Pid

/// Kill the owner process of each `client.stream_yielder` stream that the
/// calling process reads, and wait until it stopped. Returns the number of
/// killed owners.
@external(erlang, "application_ffi", "kill_stream_owner")
pub fn kill_yielder_owner() -> Int
