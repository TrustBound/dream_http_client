import dream_http_client/client
import gleam/option.{type Option}

pub fn model_pool() -> client.ConnectionPool {
  client.new_pool(max_connections: 3)
}

pub fn model_request(
  pool: client.ConnectionPool,
  prompt: String,
) -> client.ClientRequest {
  client.new()
  |> client.host("api.llm.example")
  |> client.path("/v1/chat")
  |> client.body(prompt)
  |> client.pool(pool)
}

pub fn pool_limit(request: client.ClientRequest) -> Option(Int) {
  client.get_pool(request)
  |> option.map(client.get_pool_max_connections)
}
