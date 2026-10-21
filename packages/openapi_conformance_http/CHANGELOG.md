## 1.0.0

- Initial release.
- `ConformanceClient` wraps any `package:http` client (including
  `MockClient`) and checks every request and response against an OpenAPI
  3.0/3.1 spec.
- Response bodies are buffered for checking and returned unchanged, with all
  response metadata preserved.
- Server-sent event streams pass through unbuffered.
- Multipart requests, failed requests, `skip` predicate and optional
  `throwOnViolation`.
