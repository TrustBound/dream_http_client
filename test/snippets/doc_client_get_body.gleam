import dream_http_client/client

pub fn request_body() -> BitArray {
  let request = client.new() |> client.body("{\"name\": \"Alice\"}")
  client.get_body(request)
}
