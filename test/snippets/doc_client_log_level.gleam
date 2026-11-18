import dream_http_client/client.{LogWarning}

pub fn warnings_only() -> Nil {
  client.transport_config()
  |> client.log_level(LogWarning)
  |> client.configure_transport()
}
