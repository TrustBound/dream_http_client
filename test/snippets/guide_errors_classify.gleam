//// Guide: Handling errors, timeouts and retries, step 1
////
//// Sorts the result of send into what the program does next.

import dream_http_client/client.{
  type HttpResponse, type SendError, type TransportError, ConnectFailed, Goaway,
  RefusedStream, RemoteClosed, RequestError, ResponseError, StreamReset,
  TimedOut, transport_error_to_string,
}
import gleam/int

pub type Outcome {
  /// The server answered with a status below 400.
  Done(response: HttpResponse)
  /// The request can work later: the server is busy, or the network failed.
  TryLater(reason: String)
  /// Sending the same request again gives the same answer.
  GiveUp(reason: String)
}

pub fn classify(result: Result(HttpResponse, SendError)) -> Outcome {
  case result {
    Ok(response) -> Done(response: response)
    Error(ResponseError(response: response)) -> classify_status(response)
    Error(RequestError(error: error)) -> classify_transport(error)
  }
}

fn classify_status(response: HttpResponse) -> Outcome {
  let reason = "HTTP " <> int.to_string(response.status)
  case response.status {
    408 | 429 | 500 | 502 | 503 | 504 -> TryLater(reason: reason)
    _ -> GiveUp(reason: reason)
  }
}

fn classify_transport(error: TransportError) -> Outcome {
  let reason = transport_error_to_string(error)
  case error {
    ConnectFailed(..) | TimedOut(..) | RemoteClosed | Goaway(..) ->
      TryLater(reason: reason)
    StreamReset(code: RefusedStream, ..) -> TryLater(reason: reason)
    _ -> GiveUp(reason: reason)
  }
}
