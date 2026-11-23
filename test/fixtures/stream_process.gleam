//// Find the process that runs a stream of `client.stream_to`, for the tests
//// that check that the stream process stops.

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
