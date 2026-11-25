//// Guide: Getting started, step 4
////
//// The main function of a program that uses the API module.

import gleam/io
import snippets/guide_getting_started_api_client.{
  describe_api_error, fetch_greeting, local_api,
}

pub fn main() -> Nil {
  case fetch_greeting(local_api()) {
    Ok(greeting) -> io.println(greeting.message)
    Error(error) -> io.println_error(describe_api_error(error))
  }
}
