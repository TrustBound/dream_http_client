# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 6.x     | ✅ Active support  |
| < 6.0   | ❌ No support      |

## What dream_http_client Is Responsible For

dream_http_client is a library that provides:
- **HTTP requests** - `send()`, `stream_yielder()` and `start_stream()` over HTTP/1.1 and HTTP/2, built on [gun](https://github.com/ninenines/gun)
- **TLS verification** - Server certificates are checked against the system certificate authorities, or against the PEM file you set with `certificate_authority_file()`
- **Connection pooling** - Shared connections per scheme, host, port, protocols and certificate authority file
- **Redirect following** - Automatic redirects, which you can turn off with `auto_redirect(False)`
- **Recording and playback** - Request and response recordings on disk, with transformers to scrub secrets before they are written

dream_http_client is **not a framework**. You build the application. You decide which servers to call and what to send.

This means dream_http_client's security surface is:
- TLS certificate and hostname verification
- Connections shared between requests that must not share them
- Redirects to places the request did not ask for
- Secrets written to recording files
- Resource exhaustion (connections, memory, processes)

## What You're Responsible For

Your application code handles:
- **Credentials** - You choose which tokens and headers each request carries
- **Untrusted URLs** - You validate URLs that come from users before you request them
- **Recording files** - You scrub secrets with request and response transformers, and you decide whether recordings go into version control
- **Response handling** - You validate what servers send back

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub issues.**

Email: **engineering@trustbound.ai**

### What to Include

- **Type of vulnerability** (e.g., TLS verification bypass, secret written to disk)
- **Location** in dream_http_client's code (file/function)
- **Steps to reproduce** with minimal example
- **Impact** - What can an attacker do?
- **Proof-of-concept** if you have one

Focus on vulnerabilities in **dream_http_client's code**, not in your application code.

### What to Expect

1. **Acknowledgment** within 48 hours
2. **Assessment** within 7 days
3. **Fix** coordinated with you on timing
4. **Release** with security advisory
5. **Credit** in the advisory (if desired)

## Security in dream_http_client

### Type Safety

Gleam's type system prevents many vulnerabilities:
- ✅ No null pointer exceptions
- ✅ No buffer overflows
- ✅ Exhaustive pattern matching
- ✅ Immutable data structures

### TLS

- ✅ `verify_peer` on every HTTPS connection
- ✅ Hostname checks with the HTTPS match function of `public_key`
- ✅ Requests that trust different certificate authorities never share a connection

## Dependencies

dream_http_client's dependencies:
- **gun** - HTTP/1.1 and HTTP/2 client
- **gleam_http**, **gleam_json**, **gleam_yielder** - Types and encoding
- **gleam_erlang**, **gleam_otp** - Processes
- **gleam_crypto** - Hashes for recording file names
- **simplifile** - Recording files
- **Gleam stdlib** - Type-safe, battle-tested
- **BEAM/OTP** - 30+ years of production use

We monitor dependencies and update promptly for security issues.

## Questions?

- **Security questions**: engineering@trustbound.ai
- **Non-security issues**: [GitHub Issues](https://github.com/TrustBound/dream_http_client/issues)
- **General discussion**: [GitHub Discussions](https://github.com/TrustBound/dream/discussions)

---

**Remember:** dream_http_client is a library. It provides tools. You write the application. You're responsible for your application's security.
