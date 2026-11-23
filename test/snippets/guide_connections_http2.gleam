//// Guide: Controlling connections, step 2
////
//// A request to a plain-HTTP service that speaks HTTP/2.

import dream_http_client/client.{type ClientRequest, Http2Only, path, protocols}

pub fn feed_request(api: ClientRequest) -> ClientRequest {
  api
  |> path("/stream/fast")
  |> protocols(Http2Only)
}
