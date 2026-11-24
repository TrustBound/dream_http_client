//// Tests for the examples in the dream_http_client doc comments.
////
//// The requests go to dream_mock_server, which the test main starts on
//// localhost:9876.

import dream_http_client/client
import dream_http_client/recording
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/mock_server
import fixtures/recorded
import fixtures/temp_directory
import gleam/erlang/process
import gleam/http
import gleam/option.{None, Some}
import gleam/result
import snippets/doc_client_add_header
import snippets/doc_client_auto_redirect
import snippets/doc_client_body
import snippets/doc_client_body_bits
import snippets/doc_client_body_text
import snippets/doc_client_call_api
import snippets/doc_client_cancel_stream
import snippets/doc_client_cancel_stream_handle
import snippets/doc_client_connect_timeout
import snippets/doc_client_describe_response
import snippets/doc_client_describe_target
import snippets/doc_client_explain_stream_failure
import snippets/doc_client_explain_transport_error
import snippets/doc_client_first_header
import snippets/doc_client_get_body
import snippets/doc_client_get_headers
import snippets/doc_client_get_host
import snippets/doc_client_get_log_level
import snippets/doc_client_get_method
import snippets/doc_client_get_path
import snippets/doc_client_get_port
import snippets/doc_client_get_protocols
import snippets/doc_client_get_query
import snippets/doc_client_get_recorder
import snippets/doc_client_get_scheme
import snippets/doc_client_get_timeout
import snippets/doc_client_headers
import snippets/doc_client_host
import snippets/doc_client_http2_only
import snippets/doc_client_is_stream_active
import snippets/doc_client_method
import snippets/doc_client_new
import snippets/doc_client_on_stream_chunk
import snippets/doc_client_on_stream_end
import snippets/doc_client_on_stream_error
import snippets/doc_client_on_stream_start
import snippets/doc_client_path
import snippets/doc_client_pool
import snippets/doc_client_port
import snippets/doc_client_query
import snippets/doc_client_record_call
import snippets/doc_client_recorder
import snippets/doc_client_request_id
import snippets/doc_client_request_settings
import snippets/doc_client_scheme
import snippets/doc_client_send_error
import snippets/doc_client_stream_failure_to_string
import snippets/doc_client_stream_handle
import snippets/doc_client_stream_to_string
import snippets/doc_client_timeout
import snippets/doc_client_transport_error_to_string
import snippets/doc_client_transport_getters
import snippets/doc_client_transport_tuning
import snippets/doc_matching_key
import snippets/doc_matching_scrubbed_key
import snippets/doc_recorder_add_recording
import snippets/doc_recorder_builder
import snippets/doc_recorder_builder_steps
import snippets/doc_recorder_find_recording
import snippets/doc_recorder_get_recordings
import snippets/doc_recorder_is_record_mode
import snippets/doc_recorder_record_and_stop
import snippets/doc_recorder_request_transformer
import snippets/doc_recorder_start
import snippets/doc_recorder_stop
import snippets/doc_recorder_transform_response
import snippets/doc_recording_chunk
import snippets/doc_recording_decode
import snippets/doc_recording_encode
import snippets/doc_recording_file
import snippets/doc_recording_recording
import snippets/doc_recording_request
import snippets/doc_recording_response
import snippets/doc_storage_load
import snippets/doc_storage_save_many
import snippets/doc_storage_save_one

pub fn tests() -> TestSuite {
  describe("doc comment snippets", [
    group("doc_client_transport_tuning", [
      it("tuned_transport sets every pool setting", fn() {
        // Act
        let value =
          doc_client_transport_tuning.tuned_transport()
          |> doc_client_transport_getters.pool_settings

        // Assert
        value
        |> should
        |> be_equal([
          100, 30_000, 5000, 2000, 5000, 10_000, 3, 200, 1_048_576, 262_144,
          5000,
        ])
        |> or_fail_with("Every setting should be read back")
      }),
      it("tuned_transport sets the certificate authority file", fn() {
        // Act
        let value =
          doc_client_transport_tuning.tuned_transport()
          |> doc_client_transport_getters.trusted_file

        // Assert
        value
        |> should
        |> be_equal(Some("certs/ca.pem"))
        |> or_fail_with("The file should be read back")
      }),
    ]),
    group("doc_client_transport_getters", [
      it("trusted_file is None by default", fn() {
        // Act
        let value =
          doc_client_transport_getters.trusted_file(client.transport_config())

        // Assert
        value
        |> should
        |> be_equal(None)
        |> or_fail_with("No file is set by default")
      }),
    ]),
    group("doc_client_body_text", [
      it("text_of gives the text of a UTF-8 body", fn() {
        // Arrange
        let response =
          client.HttpResponse(status: 200, headers: [], body: <<"Hello">>)

        // Act
        let value = doc_client_body_text.text_of(response)

        // Assert
        value
        |> should
        |> be_equal("Hello")
        |> or_fail_with("A UTF-8 body should be read as text")
      }),
      it("text_of says when the body is not text", fn() {
        // Arrange
        let response =
          client.HttpResponse(status: 200, headers: [], body: <<255, 0>>)

        // Act
        let value = doc_client_body_text.text_of(response)

        // Assert
        value
        |> should
        |> be_equal("The body is not text")
        |> or_fail_with("A body that is not UTF-8 has no text")
      }),
    ]),
    group("doc_client_pool", [
      it("pool_limit reads the limit of the pool of the request", fn() {
        // Arrange
        let pool = doc_client_pool.model_pool()

        // Act
        let value =
          doc_client_pool.model_request(pool, "Hello")
          |> doc_client_pool.pool_limit

        // Assert
        value
        |> should
        |> be_equal(Some(3))
        |> or_fail_with("The limit of the pool should be read back")
      }),
      it("get_pool gives the pool of the request", fn() {
        // Arrange
        let pool = doc_client_pool.model_pool()

        // Act
        let value =
          doc_client_pool.model_request(pool, "Hello") |> client.get_pool

        // Assert
        value
        |> should
        |> be_equal(Some(pool))
        |> or_fail_with("The request should have the pool it was given")
      }),
      it("get_pool gives None for a request with no pool", fn() {
        // Act
        let value = client.new() |> client.get_pool

        // Assert
        value
        |> should
        |> be_equal(None)
        |> or_fail_with("A new request should use the default pool")
      }),
    ]),
    group("doc_client_request_settings", [
      it("request_settings reads the request settings", fn() {
        // Act
        let value =
          doc_client_request_settings.internal_request()
          |> doc_client_request_settings.request_settings

        // Assert
        value
        |> should
        |> be_equal(#(Some("certs/internal-ca.pem"), Some(2000), Some(False)))
        |> or_fail_with("Every setting should be read back")
      }),
    ]),
    group("doc_recorder_builder_steps", [
      it("record_builder sets the mode and directory", fn() {
        // Act
        let value =
          doc_recorder_builder_steps.record_builder("mocks")
          |> fn(builder) { #(builder.mode, builder.directory) }

        // Assert
        value
        |> should
        |> be_equal(#("record", Some("mocks")))
        |> or_fail_with("The mode and directory should be set")
      }),
      it("record_builder drops the request headers", fn() {
        // Act
        let value =
          doc_recorder_builder_steps.record_builder("mocks").request_transformer(
            recorded.secret_post_request("s3cr3t"),
          ).headers

        // Assert
        value
        |> should
        |> be_equal([])
        |> or_fail_with("The request transformer should drop the headers")
      }),
      it("record_builder drops the response body", fn() {
        // Act
        let value =
          doc_recorder_builder_steps.record_builder("mocks").response_transformer(
            recorded.text_request(),
            recorded.ok_response("secret"),
          )

        // Assert
        value
        |> should
        |> be_equal(recorded.ok_response(""))
        |> or_fail_with("The response transformer should drop the body")
      }),
    ]),
    group("doc_recorder_transform_response", [
      it("scrubbed drops the body", fn() {
        // Act
        let value =
          doc_recorder_transform_response.scrubbed(
            temp_directory.path("doc_transform_response"),
            recorded.text_request(),
            recorded.ok_response("secret"),
          )

        // Assert
        value
        |> should
        |> be_equal(Ok(recorded.ok_response("")))
        |> or_fail_with("The recorder should apply the response transformer")
      }),
    ]),
    group("doc_client_add_header", [
      it("json_api_request adds both headers", fn() {
        // Act
        let value =
          doc_client_add_header.json_api_request("secret") |> client.get_headers

        // Assert
        value
        |> should
        |> be_equal([
          client.Header("Content-Type", "application/json"),
          client.Header("Authorization", "Bearer secret"),
        ])
        |> or_fail_with("json_api_request adds both headers")
      }),
    ]),
    group("doc_client_auto_redirect", [
      it("redirect_status returns the 301", fn() {
        // Act
        let value = doc_client_auto_redirect.redirect_status()

        // Assert
        value
        |> should
        |> be_equal(Ok(301))
        |> or_fail_with("redirect_status returns the 301")
      }),
    ]),
    group("doc_client_body", [
      it("create_user_request sets the JSON body", fn() {
        // Act
        let value = doc_client_body.create_user_request() |> client.get_body

        // Assert
        value
        |> should
        |> be_equal(<<"{\"name\":\"Alice\",\"email\":\"alice@example.com\"}">>)
        |> or_fail_with("create_user_request sets the JSON body")
      }),
    ]),
    group("doc_client_body_bits", [
      it("upload_request sets the exact bytes of the body", fn() {
        // Act
        let value =
          doc_client_body_bits.upload_request(<<37, 80, 68, 70, 255, 0>>)
          |> client.get_body

        // Assert
        value
        |> should
        |> be_equal(<<37, 80, 68, 70, 255, 0>>)
        |> or_fail_with("The body should be the bytes of the file")
      }),
    ]),
    group("doc_client_call_api", [
      it("call_api returns the body", fn() {
        // Act
        let value = doc_client_call_api.call_api("secret")

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("call_api returns the body")
      }),
    ]),
    group("doc_client_cancel_stream", [
      it("start_then_cancel returns Ok(Nil)", fn() {
        // Act
        let value = doc_client_cancel_stream.start_then_cancel()

        // Assert
        value
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("start_then_cancel should cancel the stream")
      }),
    ]),
    group("doc_client_request_id", [
      it("first_message_is_ours returns Ok(True)", fn() {
        // Act
        let value = doc_client_request_id.first_message_is_ours()

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("The first message should carry the returned id")
      }),
    ]),
    group("doc_client_cancel_stream_handle", [
      it("start_then_cancel cancels the stream", fn() {
        // Act
        let value = doc_client_cancel_stream_handle.start_then_cancel()

        // Assert
        value
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("start_then_cancel cancels the stream")
      }),
    ]),
    group("doc_client_connect_timeout", [
      it("fetch_with_connect_timeout returns the body", fn() {
        // Act
        let value = doc_client_connect_timeout.fetch_with_connect_timeout()

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("fetch_with_connect_timeout returns the body")
      }),
    ]),
    group("doc_client_describe_response", [
      it("describe_response reads a 200", fn() {
        // Act
        let value =
          doc_client_describe_response.describe_response(mock_server.get(
            "/text",
          ))

        // Assert
        value
        |> should
        |> be_equal("OK: 13 bytes")
        |> or_fail_with("describe_response reads a 200")
      }),
    ]),
    group("doc_client_describe_target", [
      it("describe_target names the host and path", fn() {
        // Act
        let value = doc_client_describe_target.describe_target()

        // Assert
        value
        |> should
        |> be_equal("Calling: api.example.com/users/123")
        |> or_fail_with("describe_target names the host and path")
      }),
    ]),
    group("doc_client_explain_stream_failure", [
      it("explain_failure reads a refused connection", fn() {
        // Act
        let value =
          doc_client_explain_stream_failure.explain_failure(
            client.TransportFailure(client.ConnectFailed("Connection refused")),
          )

        // Assert
        value
        |> should
        |> be_equal("Cannot connect: Connection refused")
        |> or_fail_with("explain_failure reads a refused connection")
      }),
    ]),
    group("doc_client_explain_transport_error", [
      it("explain reads a refused stream", fn() {
        // Act
        let value =
          doc_client_explain_transport_error.explain(client.StreamReset(
            code: client.RefusedStream,
            description: "Stream reset by server.",
          ))

        // Assert
        value
        |> should
        |> be_equal("The server refused the request")
        |> or_fail_with("explain should name a refused stream")
      }),
      it("explain reads a GOAWAY", fn() {
        // Act
        let value =
          doc_client_explain_transport_error.explain(client.Goaway(
            code: client.NoError,
            description: "The connection is going away.",
          ))

        // Assert
        value
        |> should
        |> be_equal("The server is going away")
        |> or_fail_with("explain should name a GOAWAY")
      }),
      it("explain reads a timeout", fn() {
        // Act
        let value =
          doc_client_explain_transport_error.explain(client.TimedOut(
            timeout_ms: 5000,
          ))

        // Assert
        value
        |> should
        |> be_equal("Timed out after 5000ms")
        |> or_fail_with("explain reads a timeout")
      }),
    ]),
    group("doc_client_first_header", [
      it("first_header formats the header", fn() {
        // Act
        let value =
          doc_client_first_header.first_header(
            client.new() |> client.add_header("Accept", "text/plain"),
          )

        // Assert
        value
        |> should
        |> be_equal("Accept: text/plain")
        |> or_fail_with("first_header formats the header")
      }),
    ]),
    group("doc_client_get_body", [
      it("request_body reads the value", fn() {
        // Act
        let value = doc_client_get_body.request_body()

        // Assert
        value
        |> should
        |> be_equal(<<"{\"name\": \"Alice\"}">>)
        |> or_fail_with("request_body reads the value")
      }),
    ]),
    group("doc_client_get_headers", [
      it("request_headers reads the value", fn() {
        // Act
        let value = doc_client_get_headers.request_headers()

        // Assert
        value
        |> should
        |> be_equal([
          client.Header("Content-Type", "application/json"),
          client.Header("Authorization", "Bearer token"),
        ])
        |> or_fail_with("request_headers reads the value")
      }),
    ]),
    group("doc_client_get_host", [
      it("request_host reads the value", fn() {
        // Act
        let value = doc_client_get_host.request_host()

        // Assert
        value
        |> should
        |> be_equal("api.example.com")
        |> or_fail_with("request_host reads the value")
      }),
    ]),
    group("doc_client_get_log_level", [
      it("default_log_level is LogWarning", fn() {
        // Act
        let value = doc_client_get_log_level.default_log_level()

        // Assert
        value
        |> should
        |> be_equal(client.LogWarning)
        |> or_fail_with("default_log_level is LogWarning")
      }),
    ]),
    group("doc_client_get_method", [
      it("request_method reads the value", fn() {
        // Act
        let value = doc_client_get_method.request_method()

        // Assert
        value
        |> should
        |> be_equal(http.Post)
        |> or_fail_with("request_method reads the value")
      }),
    ]),
    group("doc_client_get_path", [
      it("request_path reads the value", fn() {
        // Act
        let value = doc_client_get_path.request_path()

        // Assert
        value
        |> should
        |> be_equal("/api/users")
        |> or_fail_with("request_path reads the value")
      }),
    ]),
    group("doc_client_get_port", [
      it("request_port reads the value", fn() {
        // Act
        let value = doc_client_get_port.request_port()

        // Assert
        value
        |> should
        |> be_equal(Some(8080))
        |> or_fail_with("request_port reads the value")
      }),
    ]),
    group("doc_client_get_protocols", [
      it("request_protocols reads the value", fn() {
        // Act
        let value = doc_client_get_protocols.request_protocols()

        // Assert
        value
        |> should
        |> be_equal(Some(client.Http2Only))
        |> or_fail_with("request_protocols reads the value")
      }),
    ]),
    group("doc_client_get_query", [
      it("request_query reads the value", fn() {
        // Act
        let value = doc_client_get_query.request_query()

        // Assert
        value
        |> should
        |> be_equal(Some("page=1&limit=10"))
        |> or_fail_with("request_query reads the value")
      }),
    ]),
    group("doc_client_get_recorder", [
      it("has_recorder finds the recorder", fn() {
        // Act
        let value =
          doc_client_get_recorder.has_recorder(temp_directory.path(
            "doc_get_recorder",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("has_recorder finds the recorder")
      }),
    ]),
    group("doc_client_get_scheme", [
      it("request_scheme reads the value", fn() {
        // Act
        let value = doc_client_get_scheme.request_scheme()

        // Assert
        value
        |> should
        |> be_equal(http.Http)
        |> or_fail_with("request_scheme reads the value")
      }),
    ]),
    group("doc_client_get_timeout", [
      it("request_timeout reads the value", fn() {
        // Act
        let value = doc_client_get_timeout.request_timeout()

        // Assert
        value
        |> should
        |> be_equal(Some(5000))
        |> or_fail_with("request_timeout reads the value")
      }),
    ]),
    group("doc_client_headers", [
      it("json_api_request sets both headers", fn() {
        // Act
        let value =
          doc_client_headers.json_api_request("secret") |> client.get_headers

        // Assert
        value
        |> should
        |> be_equal([
          client.Header("Authorization", "Bearer secret"),
          client.Header("Content-Type", "application/json"),
        ])
        |> or_fail_with("json_api_request sets both headers")
      }),
    ]),
    group("doc_client_host", [
      it("api_request builds the request", fn() {
        // Act
        let value = doc_client_host.api_request() |> client.get_host

        // Assert
        value
        |> should
        |> be_equal("api.example.com")
        |> or_fail_with("api_request builds the request")
      }),
    ]),
    group("doc_client_http2_only", [
      it("http2_only_request sets Http2Only", fn() {
        // Act
        let value =
          doc_client_http2_only.http2_only_request() |> client.get_protocols

        // Assert
        value
        |> should
        |> be_equal(Some(client.Http2Only))
        |> or_fail_with("http2_only_request sets Http2Only")
      }),
    ]),
    group("doc_client_is_stream_active", [
      it("running_after_start sees the stream run", fn() {
        // Act
        let value = doc_client_is_stream_active.running_after_start()

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("running_after_start sees the stream run")
      }),
    ]),
    group("doc_client_method", [
      it("post_request builds the request", fn() {
        // Act
        let value = doc_client_method.post_request() |> client.get_method

        // Assert
        value
        |> should
        |> be_equal(http.Post)
        |> or_fail_with("post_request builds the request")
      }),
    ]),
    group("doc_client_new", [
      it("user_request builds the request", fn() {
        // Act
        let value =
          doc_client_new.user_request()
          |> fn(request) {
            #(
              client.get_host(request),
              client.get_path(request),
              client.get_method(request),
            )
          }

        // Assert
        value
        |> should
        |> be_equal(#("api.example.com", "/users/123", http.Get))
        |> or_fail_with("user_request builds the request")
      }),
    ]),
    group("doc_client_on_stream_chunk", [
      it("forward_chunks sends the first chunk", fn() {
        // Arrange
        let chunks = process.new_subject()
        let assert Ok(_handle) =
          doc_client_on_stream_chunk.forward_chunks(chunks)

        // Act
        let value = process.receive(chunks, 5000)

        // Assert
        value
        |> should
        |> be_equal(Ok("Chunk 1\n"))
        |> or_fail_with("The callback should get the first chunk")
      }),
    ]),
    group("doc_client_on_stream_end", [
      it("report_end sends a message at the end", fn() {
        // Arrange
        let ends = process.new_subject()
        let assert Ok(_handle) = doc_client_on_stream_end.report_end(ends)

        // Act
        let value = process.receive(ends, 10_000)

        // Assert
        value
        |> should
        |> be_equal(Ok("Stream completed"))
        |> or_fail_with("The callback should run at the end")
      }),
    ]),
    group("doc_client_on_stream_error", [
      it("report_failure sends the HTTP status", fn() {
        // Arrange
        let failures = process.new_subject()
        let assert Ok(_handle) =
          doc_client_on_stream_error.report_failure(failures)

        // Act
        let value = process.receive(failures, 5000)

        // Assert
        value
        |> should
        |> be_equal(Ok("HTTP 500"))
        |> or_fail_with("The callback should get the HTTP failure")
      }),
    ]),
    group("doc_client_on_stream_start", [
      it("report_header_count sends the header count", fn() {
        // Arrange
        let counts = process.new_subject()
        let assert Ok(_handle) =
          doc_client_on_stream_start.report_header_count(counts)

        // Act
        let value = process.receive(counts, 5000)

        // Assert
        value
        |> should
        |> be_equal(Ok(2))
        |> or_fail_with("The callback should get the response headers")
      }),
    ]),
    group("doc_client_path", [
      it("user_request builds the request", fn() {
        // Act
        let value = doc_client_path.user_request() |> client.get_path

        // Assert
        value
        |> should
        |> be_equal("/api/users/123")
        |> or_fail_with("user_request builds the request")
      }),
    ]),
    group("doc_client_port", [
      it("local_request builds the request", fn() {
        // Act
        let value = doc_client_port.local_request() |> client.get_port

        // Assert
        value
        |> should
        |> be_equal(Some(3000))
        |> or_fail_with("local_request builds the request")
      }),
    ]),
    group("doc_client_query", [
      it("first_page_request builds the request", fn() {
        // Act
        let value = doc_client_query.first_page_request() |> client.get_query

        // Assert
        value
        |> should
        |> be_equal(Some("page=1&limit=10"))
        |> or_fail_with("first_page_request builds the request")
      }),
    ]),
    group("doc_client_record_call", [
      it("record_call returns the body", fn() {
        // Act
        let value =
          doc_client_record_call.record_call(temp_directory.path(
            "doc_record_call",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(<<"Hello, World!">>))
        |> or_fail_with("record_call returns the body")
      }),
    ]),
    group("doc_client_recorder", [
      it("recorded_request keeps the host", fn() {
        // Act
        let value =
          doc_client_recorder.recorded_request(temp_directory.path(
            "doc_client_recorder",
          ))
          |> result.map(client.get_host)

        // Assert
        value
        |> should
        |> be_equal(Ok("api.example.com"))
        |> or_fail_with("recorded_request keeps the host")
      }),
    ]),
    group("doc_client_scheme", [
      it("plain_http_request builds the request", fn() {
        // Act
        let value = doc_client_scheme.plain_http_request() |> client.get_scheme

        // Assert
        value
        |> should
        |> be_equal(http.Http)
        |> or_fail_with("plain_http_request builds the request")
      }),
    ]),
    group("doc_client_send_error", [
      it("send_and_describe reads a 404", fn() {
        // Act
        let value =
          doc_client_send_error.send_and_describe(mock_server.get("/status/404"))

        // Assert
        value
        |> should
        |> be_equal("HTTP 404")
        |> or_fail_with("send_and_describe reads a 404")
      }),
    ]),
    group("doc_client_stream_failure_to_string", [
      it("timeout_message describes the failure", fn() {
        // Act
        let value = doc_client_stream_failure_to_string.timeout_message()

        // Assert
        value
        |> should
        |> be_equal("Timed out after 5000ms")
        |> or_fail_with("timeout_message describes the failure")
      }),
    ]),
    group("doc_client_stream_handle", [
      it("run_to_end leaves no active stream", fn() {
        // Act
        let value = doc_client_stream_handle.run_to_end()

        // Assert
        value
        |> should
        |> be_equal(Ok(False))
        |> or_fail_with("run_to_end leaves no active stream")
      }),
    ]),
    group("doc_client_stream_to_string", [
      it("stream_to_string joins the chunks", fn() {
        // Act
        let value = doc_client_stream_to_string.stream_to_string()

        // Assert
        value
        |> should
        |> be_equal(
          "Chunk 1\nChunk 2\nChunk 3\nChunk 4\nChunk 5\nChunk 6\nChunk 7\nChunk 8\nChunk 9\nChunk 10\n"
          |> Ok,
        )
        |> or_fail_with("stream_to_string joins the chunks")
      }),
    ]),
    group("doc_client_timeout", [
      it("slow_request builds the request", fn() {
        // Act
        let value = doc_client_timeout.slow_request() |> client.get_timeout

        // Assert
        value
        |> should
        |> be_equal(Some(60_000))
        |> or_fail_with("slow_request builds the request")
      }),
    ]),
    group("doc_client_transport_error_to_string", [
      it("connect_failed_message describes the error", fn() {
        // Act
        let value =
          doc_client_transport_error_to_string.connect_failed_message()

        // Assert
        value
        |> should
        |> be_equal("Connection failed: Connection refused")
        |> or_fail_with("connect_failed_message describes the error")
      }),
    ]),
    group("doc_matching_key", [
      it("method_and_url_builder keys on method and URL", fn() {
        // Act
        let value =
          doc_matching_key.method_and_url_builder().key(recorded.text_request())

        // Assert
        value
        |> should
        |> be_equal("GEThttp://localhost:9876/text")
        |> or_fail_with("method_and_url_builder keys on method and URL")
      }),
    ]),
    group("doc_matching_scrubbed_key", [
      it("start_scrubbed starts in record mode", fn() {
        // Act
        let value =
          doc_matching_scrubbed_key.start_scrubbed(temp_directory.path(
            "doc_scrubbed_key",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("start_scrubbed starts in record mode")
      }),
    ]),
    group("doc_recorder_add_recording", [
      it("add_by_hand keeps the recording", fn() {
        // Act
        let value =
          doc_recorder_add_recording.add_by_hand(temp_directory.path(
            "doc_add_by_hand",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(1))
        |> or_fail_with("add_by_hand keeps the recording")
      }),
    ]),
    group("doc_recorder_builder", [
      it("playback_builder sets the mode and directory", fn() {
        // Act
        let value =
          doc_recorder_builder.playback_builder()
          |> fn(builder) { #(builder.mode, builder.directory) }

        // Assert
        value
        |> should
        |> be_equal(#("playback", Some("mocks/api")))
        |> or_fail_with("playback_builder sets the mode and directory")
      }),
    ]),
    group("doc_recorder_find_recording", [
      it("look_up_text finds the fixture", fn() {
        // Act
        let value =
          doc_recorder_find_recording.look_up_text("test/fixtures/api")

        // Assert
        value
        |> should
        |> be_equal(Ok("Found recording"))
        |> or_fail_with("look_up_text finds the fixture")
      }),
    ]),
    group("doc_recorder_get_recordings", [
      it("count_captured counts one recording", fn() {
        // Act
        let value =
          doc_recorder_get_recordings.count_captured(temp_directory.path(
            "doc_get_recordings",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok("Captured 1 recordings"))
        |> or_fail_with("count_captured counts one recording")
      }),
    ]),
    group("doc_recorder_is_record_mode", [
      it("recording_mode_active is True", fn() {
        // Act
        let value =
          doc_recorder_is_record_mode.recording_mode_active(temp_directory.path(
            "doc_is_record_mode",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("recording_mode_active is True")
      }),
    ]),
    group("doc_recorder_record_and_stop", [
      it("record_and_stop records and stops", fn() {
        // Act
        let value =
          doc_recorder_record_and_stop.record_and_stop(temp_directory.path(
            "doc_record_and_stop",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok(Nil))
        |> or_fail_with("record_and_stop records and stops")
      }),
    ]),
    group("doc_recorder_request_transformer", [
      it("scrubbing_builder drops the Authorization header", fn() {
        // Act
        let value =
          doc_recorder_request_transformer.scrubbing_builder().request_transformer(
            recorded.secret_post_request("s3cr3t"),
          ).headers

        // Assert
        value
        |> should
        |> be_equal([#("X-Ok", "1")])
        |> or_fail_with("scrubbing_builder drops the Authorization header")
      }),
    ]),
    group("doc_recorder_start", [
      it("start_playback starts in playback mode", fn() {
        // Act
        let value = doc_recorder_start.start_playback("test/fixtures/api")

        // Assert
        value
        |> should
        |> be_equal(Ok(False))
        |> or_fail_with("start_playback starts in playback mode")
      }),
    ]),
    group("doc_recorder_stop", [
      it("start_and_stop stops the recorder", fn() {
        // Act
        let value =
          doc_recorder_stop.start_and_stop(temp_directory.path(
            "doc_recorder_stop",
          ))

        // Assert
        value
        |> should
        |> be_equal(Ok("Recorder stopped"))
        |> or_fail_with("start_and_stop stops the recorder")
      }),
    ]),
    group("doc_recording_chunk", [
      it("greeting_chunk waits 50ms", fn() {
        // Act
        let value = doc_recording_chunk.greeting_chunk().delay_ms

        // Assert
        value
        |> should
        |> be_equal(50)
        |> or_fail_with("greeting_chunk waits 50ms")
      }),
    ]),
    group("doc_recording_decode", [
      it("count_entries reads the fixture", fn() {
        // Act
        let value =
          doc_recording_decode.count_entries(
            "test/fixtures/api/GET_localhost__text_7646ad.json",
          )

        // Assert
        value
        |> should
        |> be_equal(Ok("Loaded 1 recording(s)"))
        |> or_fail_with("count_entries reads the fixture")
      }),
    ]),
    group("doc_recording_encode", [
      it("to_json_string encodes an empty file", fn() {
        // Act
        let value = doc_recording_encode.to_json_string([])

        // Assert
        value
        |> should
        |> be_equal("{\"version\":\"1.0\",\"entries\":[]}")
        |> or_fail_with("to_json_string encodes an empty file")
      }),
    ]),
    group("doc_recording_file", [
      it("file_of uses version 1.0", fn() {
        // Act
        let value = doc_recording_file.file_of([]).version

        // Assert
        value
        |> should
        |> be_equal("1.0")
        |> or_fail_with("file_of uses version 1.0")
      }),
    ]),
    group("doc_recording_recording", [
      it("pair keeps the request", fn() {
        // Act
        let value =
          doc_recording_recording.pair(
            recorded.text_request(),
            recorded.ok_response("hi"),
          ).request

        // Assert
        value
        |> should
        |> be_equal(recorded.text_request())
        |> or_fail_with("pair keeps the request")
      }),
    ]),
    group("doc_recording_request", [
      it("user_request keeps the query", fn() {
        // Act
        let value = doc_recording_request.user_request().query

        // Assert
        value
        |> should
        |> be_equal(Some("fields=name,email"))
        |> or_fail_with("user_request keeps the query")
      }),
    ]),
    group("doc_recording_response", [
      it("streaming holds two chunks", fn() {
        // Act
        let value = doc_recording_response.streaming()

        // Assert
        value
        |> should
        |> be_equal(
          recording.StreamingResponse(
            status: 200,
            headers: [#("Content-Type", "text/event-stream")],
            chunks: [
              recording.Chunk(data: <<"chunk1":utf8>>, delay_ms: 100),
              recording.Chunk(data: <<"chunk2":utf8>>, delay_ms: 100),
            ],
          ),
        )
        |> or_fail_with("streaming holds two chunks")
      }),
      it("blocking holds the body", fn() {
        // Act
        let value = doc_recording_response.blocking()

        // Assert
        value
        |> should
        |> be_equal(
          recording.BlockingResponse(
            status: 200,
            headers: [#("Content-Type", "application/json")],
            body: <<"{\"users\": []}">>,
          ),
        )
        |> or_fail_with("blocking holds the body")
      }),
    ]),
    group("doc_storage_load", [
      it("describe_recordings counts the fixture", fn() {
        // Act
        let value = doc_storage_load.describe_recordings("test/fixtures/api")

        // Assert
        value
        |> should
        |> be_equal("Loaded 1 recordings")
        |> or_fail_with("describe_recordings counts the fixture")
      }),
    ]),
    group("doc_storage_save_many", [
      it("save_all saves the recordings", fn() {
        // Act
        let value =
          doc_storage_save_many.save_all(
            temp_directory.path("doc_storage_save_many"),
            [recorded.text_recording()],
          )

        // Assert
        value
        |> should
        |> be_equal("Saved recordings successfully")
        |> or_fail_with("save_all saves the recordings")
      }),
    ]),
    group("doc_storage_save_one", [
      it("save_one saves the recording", fn() {
        // Act
        let value =
          doc_storage_save_one.save_one(
            temp_directory.path("doc_storage_save_one"),
            recorded.text_recording(),
          )

        // Assert
        value
        |> should
        |> be_equal("Saved recording")
        |> or_fail_with("save_one saves the recording")
      }),
    ]),
  ])
}
