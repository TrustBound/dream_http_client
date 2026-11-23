//// Guide: Streaming a response, step 3
////
//// Counts the bytes of a stream, and tells each kind of failure apart.

import dream_http_client/client.{
  type ClientRequest, type StreamFailure, ConnectFailed, HttpFailure, TimedOut,
  TransportFailure, stream_yielder, transport_error_to_string,
}
import gleam/bytes_tree.{type BytesTree}
import gleam/yielder

pub type DownloadError {
  /// The server answered with a status that is not 2xx. No chunk came.
  Refused(status: Int, body: BitArray)
  /// The client could not connect. No chunk came.
  Unreachable(reason: String)
  /// The server sent nothing for `waited_ms` while the client waited.
  Stalled(received: Int, waited_ms: Int)
  /// The connection broke after `received` bytes.
  Broken(received: Int, reason: String)
}

pub fn count_bytes(request: ClientRequest) -> Result(Int, DownloadError) {
  stream_yielder(request)
  |> yielder.try_fold(0, add_chunk)
}

fn add_chunk(
  received: Int,
  chunk_result: Result(BytesTree, StreamFailure),
) -> Result(Int, DownloadError) {
  case chunk_result {
    Ok(chunk) -> Ok(received + bytes_tree.byte_size(chunk))
    Error(failure) -> Error(describe_failure(failure, received))
  }
}

fn describe_failure(failure: StreamFailure, received: Int) -> DownloadError {
  case failure {
    HttpFailure(response: response) ->
      Refused(status: response.status, body: response.body)
    TransportFailure(error: ConnectFailed(reason: reason)) ->
      Unreachable(reason: reason)
    TransportFailure(error: TimedOut(timeout_ms: timeout_ms)) ->
      Stalled(received: received, waited_ms: timeout_ms)
    TransportFailure(error: error) ->
      Broken(received: received, reason: transport_error_to_string(error))
  }
}
