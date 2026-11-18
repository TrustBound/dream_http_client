import dream_mock_server/server
import dream_test/coverage
import dream_test/discover.{from_path, to_suites}
import dream_test/parallel
import dream_test/reporters/bdd
import dream_test/reporters/progress
import dream_test/runner
import fixtures/mock_server
import fixtures/temp_directory
import simplifile

pub fn main() {
  // Start every run with no scratch recordings from an earlier run.
  let assert Ok(Nil) = simplifile.create_directory_all(temp_directory.root)
  let assert Ok(Nil) = simplifile.delete(temp_directory.root)

  // Every suite that sends a request talks to this local mock server, so
  // the tests need no network.
  let assert Ok(_handle) = server.start(mock_server.port())

  let suites =
    discover.new()
    |> from_path("dream_http_client/**_test.gleam")
    |> to_suites()

  // These suites stop and start the application, so they run last and one
  // test at a time.
  let lifecycle_suites =
    discover.new()
    |> from_path("lifecycle/**_test.gleam")
    |> to_suites()

  runner.new(suites)
  |> runner.add_suites_with_config(
    parallel.ParallelConfig(max_concurrency: 1, default_timeout_ms: 30_000),
    lifecycle_suites,
  )
  |> runner.default_timeout_ms(30_000)
  |> runner.progress_reporter(progress.new())
  |> runner.results_reporters([bdd.new() |> bdd.color()])
  |> runner.coverage(
    coverage.new()
    |> coverage.show_missing()
    |> coverage.minimum_percent(100.0)
    |> coverage.json_path("build/coverage/coverage.json"),
  )
  |> runner.exit_on_failure()
  |> runner.run()
}
