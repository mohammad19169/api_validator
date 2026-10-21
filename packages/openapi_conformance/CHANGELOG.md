## 1.0.0

Initial release.

- Load OpenAPI 3.0 and 3.1 documents from YAML or JSON (`OpenApiSpec`).
- `ConformanceChecker` validates requests (path, query, header and cookie
  parameters, body, security) and responses (status, headers, body).
- JSON Schema validator covering OpenAPI 3.0 and 3.1 keywords, formats,
  discriminators, `readOnly`/`writeOnly` and recursive references.
- Strict and lenient modes, ignore lists and custom formats.
- Sealed `Violation` hierarchy with JSON paths and readable messages.
- API coverage tracking with mergeable JSON reports.
- Text, JSON, JUnit XML and GitHub Actions reporters.
- `FakeData` generator for schema-valid requests and responses.
- `EdgeCases` generator for parser robustness tests.
- `SpecDiff` to find client-breaking changes between two spec versions.
- HAR 1.2 import.
- `openapi_conformance` command line tool: `check`, `diff`, `coverage`
  and `fake`.
