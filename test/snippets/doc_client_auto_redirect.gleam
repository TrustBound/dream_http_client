import dream_http_client/client
import gleam/http
import gleam/result

pub fn redirect_status() -> Result(Int, client.SendError) {
  // Disable auto-redirect to inspect the 3xx response
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/redirect/301")
  |> client.auto_redirect(False)
  |> client.send()
  |> result.map(fn(response) { response.status })
}
