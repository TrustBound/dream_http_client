//// Read the messages that stream callbacks send to a test process.

import gleam/bit_array
import gleam/erlang/process
import gleam/list

/// Every message on `subject`, oldest first. Stops when no message arrives
/// for 100 ms.
pub fn drain(subject: process.Subject(a)) -> List(a) {
  drain_loop(subject, [])
}

fn drain_loop(subject: process.Subject(a), received: List(a)) -> List(a) {
  case process.receive(subject, 100) {
    Ok(message) -> drain_loop(subject, [message, ..received])
    Error(Nil) -> list.reverse(received)
  }
}

/// Every chunk on `subject`, joined in arrival order.
pub fn drain_bits(subject: process.Subject(BitArray)) -> BitArray {
  drain(subject) |> bit_array.concat
}

/// The first `count` messages on `subject`, oldest first. Waits up to
/// `timeout_ms` for each message, and stops early when one does not come.
pub fn take(
  subject: process.Subject(a),
  count: Int,
  timeout_ms: Int,
) -> List(a) {
  take_loop(subject, count, timeout_ms, [])
}

fn take_loop(
  subject: process.Subject(a),
  remaining: Int,
  timeout_ms: Int,
  received: List(a),
) -> List(a) {
  case remaining <= 0 {
    True -> list.reverse(received)
    False -> take_next(subject, remaining, timeout_ms, received)
  }
}

fn take_next(
  subject: process.Subject(a),
  remaining: Int,
  timeout_ms: Int,
  received: List(a),
) -> List(a) {
  case process.receive(subject, timeout_ms) {
    Ok(message) ->
      take_loop(subject, remaining - 1, timeout_ms, [message, ..received])
    Error(Nil) -> list.reverse(received)
  }
}
