import dream_http_client/recorder.{directory, mode}

pub fn playback_builder() -> recorder.RecorderBuilder {
  recorder.new()
  |> directory("mocks/api")
  |> mode(recorder.Playback)
}
