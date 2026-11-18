import dream_http_client/client

pub fn allow_more_connections() -> Nil {
  client.transport_config()
  |> client.max_connections(200)
  |> client.configure_transport()
}
