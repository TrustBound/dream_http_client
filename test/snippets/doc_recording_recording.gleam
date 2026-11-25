import dream_http_client/recording

pub fn pair(
  recorded_request: recording.RecordedRequest,
  recorded_response: recording.RecordedResponse,
) -> recording.Recording {
  recording.Recording(request: recorded_request, response: recorded_response)
}
