//// Guide: Sending data to an API, step 4
////
//// Adds the headers that an API asks for to every request.

import dream_http_client/client.{type ClientRequest, add_header}

pub fn authorized(api: ClientRequest, token: String) -> ClientRequest {
  api
  |> add_header("Authorization", "Bearer " <> token)
  |> add_header("User-Agent", "greeter/1.0")
}
