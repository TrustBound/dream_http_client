import dream_http_client/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/recorded
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn tests() -> TestSuite {
  describe("dream_http_client/recording", [
    group("encode_recording_file", [
      it("encodes a blocking entry", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Get,
                scheme: http.Https,
                host: "api.example.com",
                port: None,
                path: "/users",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [#("Content-Type", "application/json")],
                body: <<"{\"users\": []}">>,
              ),
            ),
          ])

        // Act
        let encoded = recording.encode_recording_file(file) |> json.to_string

        // Assert
        encoded
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"api.example.com\",\"port\":null,\"path\":\"/users\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[[\"Content-Type\",\"application/json\"]],\"body\":\"{\\\"users\\\": []}\"}}]}",
        )
        |> or_fail_with("The blocking entry should encode to this JSON")
      }),
      it("encodes a streaming entry with text and binary chunks", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Other("purge"),
                scheme: http.Http,
                host: "localhost",
                port: Some(8080),
                path: "/stream",
                query: Some("a=1"),
                headers: [#("Accept", "text/event-stream")],
                body: <<>>,
              ),
              response: recording.StreamingResponse(
                status: 200,
                headers: [],
                chunks: [
                  recording.Chunk(data: <<"chunk1">>, delay_ms: 50),
                  recording.Chunk(data: <<255, 0>>, delay_ms: 10),
                ],
              ),
            ),
          ])

        // Act
        let encoded = recording.encode_recording_file(file) |> json.to_string

        // Assert
        encoded
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"PURGE\",\"scheme\":\"http\",\"host\":\"localhost\",\"port\":8080,\"path\":\"/stream\",\"query\":\"a=1\",\"headers\":[[\"Accept\",\"text/event-stream\"]],\"body\":\"\"},\"response\":{\"mode\":\"streaming\",\"status\":200,\"headers\":[],\"chunks\":[{\"data\":\"chunk1\",\"delay_ms\":50},{\"data\":\"/wA=\",\"data_encoding\":\"base64\",\"delay_ms\":10}]}}]}",
        )
        |> or_fail_with("Binary chunks should be base64 encoded")
      }),
      it("encodes an empty file", fn() {
        // Arrange
        let file = recording.RecordingFile(version: "1.0", entries: [])

        // Act
        let encoded = recording.encode_recording_file(file) |> json.to_string

        // Assert
        encoded
        |> should
        |> be_equal("{\"version\":\"1.0\",\"entries\":[]}")
        |> or_fail_with("An empty file should encode to an empty entry list")
      }),
    ]),
    group("decode_recording_file", [
      it("decodes a blocking entry", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"api.example.com\",\"port\":null,\"path\":\"/users\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"{\\\"users\\\": []}\"}}]}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(
          Ok(
            recording.RecordingFile(version: "1.0", entries: [
              recording.Recording(
                request: recording.RecordedRequest(
                  method: http.Get,
                  scheme: http.Https,
                  host: "api.example.com",
                  port: None,
                  path: "/users",
                  query: None,
                  headers: [],
                  body: <<>>,
                ),
                response: recording.BlockingResponse(
                  status: 200,
                  headers: [],
                  body: <<"{\"users\": []}">>,
                ),
              ),
            ]),
          ),
        )
        |> or_fail_with("The blocking entry should decode")
      }),
      it("decodes a streaming entry", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"api.example.com\",\"port\":null,\"path\":\"/stream\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"streaming\",\"status\":200,\"headers\":[],\"chunks\":[{\"data\":\"chunk1\",\"delay_ms\":50},{\"data\":\"/wA=\",\"data_encoding\":\"base64\",\"delay_ms\":10}]}}]}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(
          Ok(
            recording.RecordingFile(version: "1.0", entries: [
              recording.Recording(
                request: recording.RecordedRequest(
                  method: http.Get,
                  scheme: http.Https,
                  host: "api.example.com",
                  port: None,
                  path: "/stream",
                  query: None,
                  headers: [],
                  body: <<>>,
                ),
                response: recording.StreamingResponse(
                  status: 200,
                  headers: [],
                  chunks: [
                    recording.Chunk(data: <<"chunk1">>, delay_ms: 50),
                    recording.Chunk(data: <<255, 0>>, delay_ms: 10),
                  ],
                ),
              ),
            ]),
          ),
        )
        |> or_fail_with("The streaming entry should decode")
      }),
      it("decodes an empty entry list", fn() {
        // Arrange
        let text = "{\"version\":\"1.0\",\"entries\":[]}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Ok(recording.RecordingFile(version: "1.0", entries: [])))
        |> or_fail_with("An empty entry list should decode")
      }),
      it("returns an error for text that is not JSON", fn() {
        // Arrange
        let text = "{invalid json}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Unexpected byte: 0x69"))
        |> or_fail_with("Invalid JSON should give the unexpected byte")
      }),
      it("returns an error for a bad escape sequence", fn() {
        // Arrange
        let text = "\"\\uZZZZ\""

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Unexpected sequence: \\uZZZZ"))
        |> or_fail_with("A bad escape should give the unexpected sequence")
      }),
      it("returns an error for JSON that ends early", fn() {
        // Arrange
        let text = "{\"version\":"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Unexpected end of JSON input"))
        |> or_fail_with("Truncated JSON should give unexpected end")
      }),
      it("returns an error for a missing entries field", fn() {
        // Arrange
        let text = "{\"version\":\"1.0\"}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Expected Field, found Nothing at entries"))
        |> or_fail_with("A missing entries field should be named")
      }),
      it("returns an error for a null version", fn() {
        // Arrange
        let text = "{\"version\":null,\"entries\":[]}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Expected String, found Nil at version"))
        |> or_fail_with("A null version should be named")
      }),
      it("returns an error for a missing version", fn() {
        // Arrange
        let text = "{\"entries\":[]}"

        // Act
        let decoded = recording.decode_recording_file(text)

        // Assert
        decoded
        |> should
        |> be_equal(Error("Expected Field, found Nothing at version"))
        |> or_fail_with("A missing version should be named")
      }),
    ]),
    group("methods, schemes and encodings", [
      it("encodes the PUT method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Put,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"PUT\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("PUT should encode as PUT")
      }),
      it("encodes the DELETE method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Delete,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"DELETE\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("DELETE should encode as DELETE")
      }),
      it("encodes the PATCH method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Patch,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"PATCH\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("PATCH should encode as PATCH")
      }),
      it("encodes the HEAD method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Head,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"HEAD\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("HEAD should encode as HEAD")
      }),
      it("encodes the OPTIONS method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Options,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"OPTIONS\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("OPTIONS should encode as OPTIONS")
      }),
      it("encodes the TRACE method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Trace,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"TRACE\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("TRACE should encode as TRACE")
      }),
      it("encodes the CONNECT method", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Connect,
                scheme: http.Https,
                host: "h",
                port: None,
                path: "/",
                query: None,
                headers: [],
                body: <<>>,
              ),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<>>,
              ),
            ),
          ])

        // Act
        let value = recording.encode_recording_file(file) |> json.to_string

        // Assert
        value
        |> should
        |> be_equal(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"CONNECT\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        )
        |> or_fail_with("CONNECT should encode as CONNECT")
      }),
      it("decodes the method get", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"get\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Get]))
        |> or_fail_with("get should decode")
      }),
      it("decodes the method post", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"post\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Post]))
        |> or_fail_with("post should decode")
      }),
      it("decodes the method put", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"put\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Put]))
        |> or_fail_with("put should decode")
      }),
      it("decodes the method delete", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"delete\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Delete]))
        |> or_fail_with("delete should decode")
      }),
      it("decodes the method patch", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"patch\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Patch]))
        |> or_fail_with("patch should decode")
      }),
      it("decodes the method head", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"head\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Head]))
        |> or_fail_with("head should decode")
      }),
      it("decodes the method options", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"options\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Options]))
        |> or_fail_with("options should decode")
      }),
      it("decodes the method trace", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"trace\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Trace]))
        |> or_fail_with("trace should decode")
      }),
      it("decodes the method connect", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"connect\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Connect]))
        |> or_fail_with("connect should decode")
      }),
      it("decodes the method PURGE", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"PURGE\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.method })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Other("PURGE")]))
        |> or_fail_with("PURGE should decode")
      }),
      it("decodes an unknown scheme as http", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"ftp\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.scheme })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([http.Http]))
        |> or_fail_with("An unknown scheme should fall back to http")
      }),
      it("decodes an unknown response mode as blocking", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"other\",\"status\":201,\"headers\":[],\"body\":\"b\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.response })
          })

        // Assert
        value
        |> should
        |> be_equal(
          Ok([
            recording.BlockingResponse(status: 201, headers: [], body: <<"b">>),
          ]),
        )
        |> or_fail_with("An unknown mode should decode as blocking")
      }),
      it("encodes a response body that is not UTF-8 as base64", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recorded.text_request(),
              response: recording.BlockingResponse(
                status: 200,
                headers: [],
                body: <<255, 0>>,
              ),
            ),
          ])

        // Act
        let value =
          recording.encode_recording_file(file)
          |> json.to_string
          |> string.contains("\"body\":\"/wA=\",\"body_encoding\":\"base64\"")

        // Assert
        value
        |> should
        |> be_equal(True)
        |> or_fail_with("A response body that is not UTF-8 should be base64")
      }),
      it("decodes a base64 response body to its bytes", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"/wA=\",\"body_encoding\":\"base64\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) {
              case e.response {
                recording.BlockingResponse(_status, _headers, body) -> body
                recording.StreamingResponse(_status, _headers, _chunks) -> <<>>
              }
            })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([<<255, 0>>]))
        |> or_fail_with("The base64 body should decode to its bytes")
      }),
      it("decodes a base64 request body to its bytes", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"/wA=\",\"body_encoding\":\"base64\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.body })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([<<255, 0>>]))
        |> or_fail_with("The base64 body should decode to its bytes")
      }),
      it("keeps a request body that is not valid base64", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"!!!\",\"body_encoding\":\"base64\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.request.body })
          })

        // Assert
        value
        |> should
        |> be_equal(Ok([<<"!!!">>]))
        |> or_fail_with("An invalid base64 body should be kept as it is")
      }),
      it("keeps chunk data that is not valid base64", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"\"},\"response\":{\"mode\":\"streaming\",\"status\":200,\"headers\":[],\"chunks\":[{\"data\":\"!!!\",\"data_encoding\":\"base64\",\"delay_ms\":1}]}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            list.map(file.entries, fn(e) { e.response })
          })

        // Assert
        value
        |> should
        |> be_equal(
          Ok([
            recording.StreamingResponse(status: 200, headers: [], chunks: [
              recording.Chunk(data: <<"!!!">>, delay_ms: 1),
            ]),
          ]),
        )
        |> or_fail_with("Invalid base64 chunk data should be kept as text")
      }),
      it("encodes a body that is not UTF-8 as base64", fn() {
        // Arrange
        let text =
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"/wA=\",\"body_encoding\":\"base64\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}"

        // Act
        let value =
          recording.decode_recording_file(text)
          |> result.map(fn(file) {
            recording.encode_recording_file(file) |> json.to_string
          })

        // Assert
        value
        |> should
        |> be_equal(Ok(
          "{\"version\":\"1.0\",\"entries\":[{\"request\":{\"method\":\"GET\",\"scheme\":\"https\",\"host\":\"h\",\"port\":null,\"path\":\"/\",\"query\":null,\"headers\":[],\"body\":\"/wA=\",\"body_encoding\":\"base64\"},\"response\":{\"mode\":\"blocking\",\"status\":200,\"headers\":[],\"body\":\"\"}}]}",
        ))
        |> or_fail_with("A body that is not UTF-8 should be base64 encoded")
      }),
      it("returns an error for a bad escape character", fn() {
        // Arrange
        let text = "{\"version\":\"\\x\"}"

        // Act
        let value = recording.decode_recording_file(text)

        // Assert
        value
        |> should
        |> be_equal(Error("Unexpected byte: 0x78"))
        |> or_fail_with("A bad escape should be named")
      }),
    ]),
    group("round trip", [
      it("decodes what it encodes", fn() {
        // Arrange
        let file =
          recording.RecordingFile(version: "1.0", entries: [
            recording.Recording(
              request: recording.RecordedRequest(
                method: http.Post,
                scheme: http.Http,
                host: "localhost",
                port: Some(8080),
                path: "/api/data",
                query: Some("key=value"),
                headers: [#("Authorization", "Bearer token")],
                body: <<"{\"data\": \"test\"}">>,
              ),
              response: recording.BlockingResponse(
                status: 201,
                headers: [#("Content-Type", "application/json")],
                body: <<"{\"id\": 123}">>,
              ),
            ),
          ])

        // Act
        let decoded =
          recording.encode_recording_file(file)
          |> json.to_string
          |> recording.decode_recording_file

        // Assert
        decoded
        |> should
        |> be_equal(Ok(file))
        |> or_fail_with("A round trip should give back the same file")
      }),
    ]),
  ])
}
