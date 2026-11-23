import dream_http_client/recording
import gleam/http
import gleam/option

pub fn user_request() -> recording.RecordedRequest {
  recording.RecordedRequest(
    method: http.Get,
    scheme: http.Https,
    host: "api.example.com",
    port: option.None,
    path: "/users/123",
    query: option.Some("fields=name,email"),
    headers: [#("Authorization", "Bearer token123")],
    body: <<>>,
  )
}
