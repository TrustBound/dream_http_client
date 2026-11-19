import dream_http_client/client.{ConnectFailed, transport_error_to_string}

pub fn connect_failed_message() -> String {
  transport_error_to_string(ConnectFailed(reason: "Connection refused"))
}
