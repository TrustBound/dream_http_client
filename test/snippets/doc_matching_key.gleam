import dream_http_client/matching
import dream_http_client/recorder.{key}

pub fn method_and_url_builder() -> recorder.RecorderBuilder {
  let key_fn =
    matching.request_key(method: True, url: True, headers: False, body: False)

  recorder.new() |> key(key_fn)
}
