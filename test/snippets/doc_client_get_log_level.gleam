import dream_http_client/client

pub fn default_log_level() -> client.LogLevel {
  client.transport_config()
  |> client.get_log_level()
}
