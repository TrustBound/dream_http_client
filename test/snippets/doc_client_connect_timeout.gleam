import dream_http_client/client
import gleam/http
import gleam/result

pub fn fetch_with_connect_timeout() -> Result(String, client.SendError) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/text")
  |> client.connect_timeout(5000)
  |> client.send()
  |> result.map(fn(response) { response.body })
}
