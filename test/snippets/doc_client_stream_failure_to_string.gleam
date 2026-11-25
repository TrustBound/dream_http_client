import dream_http_client/client.{
  TimedOut, TransportFailure, stream_failure_to_string,
}

pub fn timeout_message() -> String {
  stream_failure_to_string(TransportFailure(error: TimedOut(timeout_ms: 5000)))
}
