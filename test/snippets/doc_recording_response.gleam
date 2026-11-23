import dream_http_client/recording

pub fn blocking() -> recording.RecordedResponse {
  recording.BlockingResponse(
    status: 200,
    headers: [#("Content-Type", "application/json")],
    body: <<"{\"users\": []}">>,
  )
}

pub fn streaming() -> recording.RecordedResponse {
  recording.StreamingResponse(
    status: 200,
    headers: [#("Content-Type", "text/event-stream")],
    chunks: [
      recording.Chunk(data: <<"chunk1":utf8>>, delay_ms: 100),
      recording.Chunk(data: <<"chunk2":utf8>>, delay_ms: 100),
    ],
  )
}
