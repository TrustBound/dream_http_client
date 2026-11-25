//// Guide: Handling errors, timeouts and retries, step 2
////
//// Sets how long a request waits for the server, and for the connection.

import dream_http_client/client.{
  type ClientRequest, type HttpResponse, type SendError, connect_timeout, path,
  send, timeout,
}

pub fn fetch_report(
  api: ClientRequest,
  wait_ms: Int,
) -> Result(HttpResponse, SendError) {
  api
  // The mock server answers /slow after 5 seconds
  |> path("/slow")
  |> connect_timeout(2000)
  |> timeout(wait_ms)
  |> send()
}
