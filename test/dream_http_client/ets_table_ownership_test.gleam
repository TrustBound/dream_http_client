//// Regression tests: ETS table ownership must not cause silent stream crashes
////
//// The `dream_http_client_ref_mapping` ETS table is created by the
//// `dream_http_client` OTP application in its `start/2` callback. The table
//// is owned by the application master process, which lives for the entire
//// application lifetime. This means:
////
//// - No short-lived process can destroy the table by exiting.
//// - No race condition on table creation (application start is serialized).
//// - No try/catch needed on ETS access (the table is always there).
////
//// The stream tests reproduce the scenario of the original bug report
//// (concurrent streams from expired callers) and verify it can never happen
//// again.

import dream_http_client/client
import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/types.{type TestSuite}
import dream_test/unit.{describe, group, it}
import fixtures/ets_table
import fixtures/mailbox
import fixtures/mock_server
import gleam/erlang/process
import gleam/int
import gleam/list

pub fn tests() -> TestSuite(Nil) {
  describe("ETS table ownership", [
    group("the ref mapping table", [
      it("exists", fn() {
        // Arrange
        let table_name = "dream_http_client_ref_mapping"

        // Act
        let exists = ets_table.exists()

        // Assert
        exists
        |> should
        |> be_equal(True)
        |> or_fail_with(table_name <> " should exist")
      }),
      it("is not owned by the test process", fn() {
        // Arrange
        let table_name = "dream_http_client_ref_mapping"

        // Act
        let not_self = ets_table.owner_is_not_self()

        // Assert
        not_self
        |> should
        |> be_equal(True)
        |> or_fail_with(table_name <> " should be owned by the application")
      }),
      it("has a live owner", fn() {
        // Arrange
        let table_name = "dream_http_client_ref_mapping"

        // Act
        let alive = ets_table.owner_is_alive()

        // Assert
        alive
        |> should
        |> be_equal(True)
        |> or_fail_with(table_name <> " owner should be alive")
      }),
      it("keeps a mapping after the writer process exits", fn() {
        // Arrange
        let done = process.new_subject()
        process.spawn_unlinked(fn() {
          ets_table.store_test_mapping()
          process.send(done, True)
        })
        let assert Ok(True) = process.receive(done, 2000)
        process.sleep(200)

        // Act
        let exists = ets_table.test_mapping_exists()
        ets_table.clear_test_mappings()

        // Assert
        exists
        |> should
        |> be_equal(True)
        |> or_fail_with("The mapping should outlive the process that wrote it")
      }),
    ]),
    group("streams", [
      it("a stream from an expired caller completes", fn() {
        // Arrange
        let ends = process.new_subject()

        // Act
        process.spawn_unlinked(fn() {
          let request =
            mock_server.get("/stream/fast")
            |> client.on_stream_end(fn(_headers) { process.send(ends, 1) })
            |> client.on_stream_error(fn(_failure) { process.send(ends, -1) })
          let assert Ok(_handle) = client.start_stream(request)
        })
        let results = mailbox.take(ends, 1, 5000)

        // Assert
        results
        |> should
        |> be_equal([1])
        |> or_fail_with("The stream should end without an error")
      }),
      it("two concurrent streams from expired callers both complete", fn() {
        // Arrange
        let ends = process.new_subject()

        // Act
        process.spawn_unlinked(fn() {
          let request =
            mock_server.get("/stream/fast")
            |> client.on_stream_end(fn(_headers) { process.send(ends, 1) })
            |> client.on_stream_error(fn(_failure) { process.send(ends, -1) })
          let assert Ok(_handle) = client.start_stream(request)
        })
        process.sleep(50)
        process.spawn_unlinked(fn() {
          let request =
            mock_server.get("/stream/slow")
            |> client.on_stream_end(fn(_headers) { process.send(ends, 2) })
            |> client.on_stream_error(fn(_failure) { process.send(ends, -2) })
          let assert Ok(_handle) = client.start_stream(request)
        })
        let results = mailbox.take(ends, 2, 15_000) |> list.sort(int.compare)

        // Assert
        results
        |> should
        |> be_equal([1, 2])
        |> or_fail_with("Both streams should end without an error")
      }),
      it("three concurrent streams from one caller all complete", fn() {
        // Arrange
        let ends = process.new_subject()

        // Act
        list.each([1, 2, 3], fn(id) {
          let request =
            mock_server.get("/stream/fast")
            |> client.on_stream_end(fn(_headers) { process.send(ends, id) })
            |> client.on_stream_error(fn(_failure) { process.send(ends, -id) })
          let assert Ok(_handle) = client.start_stream(request)
          Nil
        })
        let results = mailbox.take(ends, 3, 5000) |> list.sort(int.compare)

        // Assert
        results
        |> should
        |> be_equal([1, 2, 3])
        |> or_fail_with("All three streams should end without an error")
      }),
      it("a new stream works after an earlier stream process exits", fn() {
        // Arrange
        let ends = process.new_subject()
        let assert Ok(first) =
          client.start_stream(mock_server.get("/stream/fast"))
        client.await_stream(first)
        let request =
          mock_server.get("/stream/fast")
          |> client.on_stream_end(fn(_headers) { process.send(ends, True) })
          |> client.on_stream_error(fn(_failure) { process.send(ends, False) })

        // Act
        let assert Ok(_second) = client.start_stream(request)
        let end = process.receive(ends, 5000)

        // Assert
        end
        |> should
        |> be_equal(Ok(True))
        |> or_fail_with("The second stream should end without an error")
      }),
      it("five concurrent streams from expired callers all complete", fn() {
        // Arrange
        let ends = process.new_subject()

        // Act
        list.each([1, 2, 3, 4, 5], fn(id) {
          process.spawn_unlinked(fn() {
            let request =
              mock_server.get("/stream/fast")
              |> client.on_stream_end(fn(_headers) { process.send(ends, id) })
              |> client.on_stream_error(fn(_failure) { process.send(ends, -id) })
            let assert Ok(_handle) = client.start_stream(request)
          })
        })
        let results = mailbox.take(ends, 5, 15_000) |> list.sort(int.compare)

        // Assert
        results
        |> should
        |> be_equal([1, 2, 3, 4, 5])
        |> or_fail_with("All five streams should end without an error")
      }),
    ]),
  ])
}
