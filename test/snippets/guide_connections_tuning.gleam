//// Guide: Controlling connections, step 5
////
//// The transport settings of a busy service, in one value.

import dream_http_client/client.{type TransportConfig}

pub fn busy_service_config() -> TransportConfig {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.max_concurrent_streams(500)
}

/// Apply it once, when the program starts.
pub fn configure_busy_service() -> Nil {
  client.configure_transport(busy_service_config())
}
