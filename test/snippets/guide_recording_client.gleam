//// Guide: Testing with recorded responses, steps 1 and 2
////
//// An API function that takes its base request, and a recorder that the
//// base request can carry.

import dream_http_client/client.{
  type ClientRequest, path, send, transport_error_to_string,
}
import dream_http_client/recorder.{type Recorder, directory, mode, start}
import gleam/int
import gleam/result

/// Starts a recorder in `recorder_mode` (`Record`, `Playback` or
/// `Passthrough`) that keeps its recordings in `recordings`.
pub fn start_recorder(
  recorder_mode: recorder.Mode,
  recordings: String,
) -> Result(Recorder, String) {
  recorder.new()
  |> directory(recordings)
  |> mode(recorder_mode)
  |> start()
}

/// The text at /text. The code under test doesn't know about recorders:
/// the base request carries one, or doesn't.
pub fn fetch_text(api: ClientRequest) -> Result(String, String) {
  use response <- result.try(
    api
    |> path("/text")
    |> send()
    |> result.map_error(describe_send_error),
  )
  client.body_text(response) |> result.replace_error("The body is not text")
}

fn describe_send_error(error: client.SendError) -> String {
  case error {
    client.ResponseError(response: response) ->
      "HTTP " <> int.to_string(response.status)
    client.RequestError(error: transport_error) ->
      transport_error_to_string(transport_error)
  }
}
