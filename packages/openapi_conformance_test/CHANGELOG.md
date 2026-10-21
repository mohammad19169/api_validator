## 1.0.0

- Initial release.
- `useConformance` / `useConformanceFromFile`: fail each test whose HTTP
  traffic breaks the spec and write API coverage files per test suite.
- Matchers: `isConforming`, `hasNoViolations`, `hasViolation`, `exercised`.
- Fixture matchers: `conformsToResponse`, `conformsToRequestBody`,
  `conformsToSchema` for plain JSON values and JSON strings.
- `describeConformanceFailures` and `writeCoverageReport` helpers.
