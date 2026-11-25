import dream_http_client/client
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/int

pub fn report_failure(
  reply_to: Subject(String),
) -> Result(client.StreamHandle, String) {
  client.new()
  |> client.scheme(http.Http)
  |> client.host("localhost")
  |> client.port(9876)
  |> client.path("/status/500")
  |> client.on_stream_error(fn(failure) {
    case failure {
      client.HttpFailure(response: response) ->
        process.send(reply_to, "HTTP " <> int.to_string(response.status))
      client.TransportFailure(error: error) ->
        process.send(
          reply_to,
          "Transport: " <> client.transport_error_to_string(error),
        )
    }
  })
  |> client.start_stream()
}
