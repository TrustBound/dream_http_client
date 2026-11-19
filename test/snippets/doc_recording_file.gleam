import dream_http_client/recording

pub fn file_of(entries: List(recording.Recording)) -> recording.RecordingFile {
  recording.RecordingFile(version: "1.0", entries: entries)
}
