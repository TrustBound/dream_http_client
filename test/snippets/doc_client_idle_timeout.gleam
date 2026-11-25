import dream_http_client/client

pub fn keep_idle_connections() -> Nil {
  client.transport_config()
  |> client.idle_timeout(120_000)
  |> client.configure_transport()
}
