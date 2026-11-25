//// When the pool stops a connection whose socket the server just closed,
//// the connection still reports the closed socket, so the client logs its
//// `connection down` warning. See `connection_stop_ffi.erl`.

import dream_test/matchers.{be_equal, or_fail_with, should}
import dream_test/suite.{type TestSuite}
import dream_test/unit.{describe, it}

pub fn tests() -> TestSuite {
  describe("dream_http_conn_manager stop_connection", [
    it("a stopped connection reports the socket that it lost before", fn() {
      // Act
      let reported = down_reported_when_stopped()

      // Assert
      reported
      |> should
      |> be_equal(True)
      |> or_fail_with("The connection sends gun_down before it stops")
    }),
    it("stopping a connection that already stopped does not crash", fn() {
      // Act
      let survived = stop_stopped_connection()

      // Assert
      survived
      |> should
      |> be_equal(True)
      |> or_fail_with("A stopped connection is stopped again with no crash")
    }),
  ])
}

@external(erlang, "connection_stop_ffi", "down_reported_when_stopped")
fn down_reported_when_stopped() -> Bool

@external(erlang, "connection_stop_ffi", "stop_stopped_connection")
fn stop_stopped_connection() -> Bool
