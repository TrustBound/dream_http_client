import dream_http_client/recording

pub fn greeting_chunk() -> recording.Chunk {
  recording.Chunk(
    data: <<"Hello, ":utf8>>,
    // 50ms delay before this chunk
    delay_ms: 50,
  )
}
