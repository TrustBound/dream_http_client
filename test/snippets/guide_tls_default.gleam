//// Guide: Calling a service with a private certificate authority, step 4
////
//// Makes every request trust a private certificate authority, unless the
//// request names its own file.

import dream_http_client/client.{
  configure_transport, default_certificate_authority_file,
}

pub fn trust_company_ca(ca_file: String) -> Nil {
  client.transport_config()
  |> default_certificate_authority_file(ca_file)
  |> configure_transport()
}
