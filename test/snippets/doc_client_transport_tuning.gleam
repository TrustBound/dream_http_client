import dream_http_client/client

pub fn tuned_transport() -> client.TransportConfig {
  client.transport_config()
  |> client.max_connections(100)
  |> client.idle_timeout(30_000)
  |> client.default_connect_timeout(5000)
  |> client.domain_lookup_timeout(2000)
  |> client.tls_handshake_timeout(5000)
  |> client.retry(1)
  |> client.retry_timeout(500)
  |> client.keepalive(10_000)
  |> client.keepalive_tolerance(3)
  |> client.max_concurrent_streams(200)
  |> client.initial_connection_window_size(1_048_576)
  |> client.initial_stream_window_size(262_144)
  |> client.closing_timeout(5000)
  |> client.default_certificate_authority_file("certs/ca.pem")
}
