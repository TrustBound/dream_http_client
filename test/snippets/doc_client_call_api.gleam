import dream_http_client/client.{add_header, host, path, port, scheme, send}
import gleam/http
import gleam/result

pub fn call_api(token: String) -> Result(String, client.SendError) {
  client.new()
  |> scheme(http.Http)
  |> host("localhost")
  |> port(9876)
  |> path("/text")
  |> add_header("Authorization", "Bearer " <> token)
  |> send()
  |> result.map(fn(response) { response.body })
}
