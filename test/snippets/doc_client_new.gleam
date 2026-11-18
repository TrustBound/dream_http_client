import dream_http_client/client.{host, method, new, path}
import gleam/http.{Get}

pub fn user_request() -> client.ClientRequest {
  new()
  |> host("api.example.com")
  |> path("/users/123")
  |> method(Get)
}
