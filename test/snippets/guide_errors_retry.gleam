//// Guide: Handling errors, timeouts and retries, step 4
////
//// Sends a request again after a failure that can pass, with a growing
//// wait, and only for a method that is safe to repeat.

import dream_http_client/client.{type ClientRequest, get_method, send}
import gleam/erlang/process
import gleam/http
import gleam/list
import snippets/guide_errors_classify.{type Outcome, TryLater, classify}

pub fn send_with_retry(
  request: ClientRequest,
  attempts: Int,
  wait_ms: Int,
) -> Outcome {
  let outcome = classify(send(request))
  let may_repeat = attempts > 1 && is_safe_to_repeat(get_method(request))
  case outcome, may_repeat {
    TryLater(..), True -> {
      process.sleep(wait_ms)
      send_with_retry(request, attempts - 1, wait_ms * 2)
    }
    _, _ -> outcome
  }
}

/// The methods that RFC 9110 calls idempotent: sending one twice has the
/// same effect as sending it once.
fn is_safe_to_repeat(method: http.Method) -> Bool {
  list.contains(
    [http.Get, http.Head, http.Options, http.Trace, http.Put, http.Delete],
    method,
  )
}
