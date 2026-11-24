import dream_http_client/client.{LogInfo}

pub fn info_lines() -> Nil {
  client.transport_config()
  |> client.log_level(LogInfo)
  |> client.configure_transport()
}
