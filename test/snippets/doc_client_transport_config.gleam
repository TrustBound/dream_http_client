import dream_http_client/client

pub fn configure_pool() -> Nil {
  client.transport_config()
  |> client.max_connections(200)
  |> client.idle_timeout(120_000)
  |> client.configure_transport()
}
