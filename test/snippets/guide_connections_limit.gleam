//// Guide: Controlling connections, step 3
////
//// Limits how many connections the client opens to each host.

import dream_http_client/client.{configure_transport, max_connections}

pub fn limit_connections(limit: Int) -> Nil {
  client.transport_config()
  |> max_connections(limit)
  |> configure_transport()
}
