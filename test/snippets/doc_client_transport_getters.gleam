import dream_http_client/client
import gleam/option.{type Option}

pub fn pool_settings(config: client.TransportConfig) -> List(Int) {
  [
    client.get_max_connections(config),
    client.get_idle_timeout(config),
    client.get_default_connect_timeout(config),
    client.get_domain_lookup_timeout(config),
    client.get_tls_handshake_timeout(config),
    client.get_retry(config),
    client.get_retry_timeout(config),
    client.get_keepalive(config),
    client.get_keepalive_tolerance(config),
    client.get_max_concurrent_streams(config),
    client.get_initial_connection_window_size(config),
    client.get_initial_stream_window_size(config),
    client.get_closing_timeout(config),
  ]
}

pub fn trusted_file(config: client.TransportConfig) -> Option(String) {
  client.get_default_certificate_authority_file(config)
}
