//// Guide: Controlling connections, step 4
////
//// Gives the requests of one caller a connection pool of their own.

import dream_http_client/client.{
  type ClientRequest, type ConnectionPool, new_pool, path, pool,
}

/// Make the pool once, when the program starts, and keep it.
pub fn reports_pool() -> ConnectionPool {
  new_pool(max_connections: 1)
}

pub fn report_request(
  api: ClientRequest,
  reports: ConnectionPool,
) -> ClientRequest {
  api
  |> path("/stream/fast")
  |> pool(reports)
}
