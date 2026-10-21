## 1.0.1

- Require openapi_conformance 1.0.1, which fixes a file missing from the
  1.0.0 release.

## 1.0.0

- Initial release.
- `ConformanceInterceptor` checks every dio request and response against an
  OpenAPI 3.0/3.1 spec, including responses produced by mock adapters.
- Error responses and connection failures are checked through `onError`.
- Optional `throwOnViolation` turns non-conforming exchanges into a
  `DioException` carrying a `ConformanceException`.
- `FormData`, byte and already decoded bodies are supported.
- `dio.addConformance(checker)` extension and `exchangeFromDio` helper.
