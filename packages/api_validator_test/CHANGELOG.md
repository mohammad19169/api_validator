## 1.0.0

- Initial release.
- `useApiValidator` / `useApiValidatorFromFile`: fail each test whose HTTP
  traffic breaks the spec and write API coverage files per test suite.
- Matchers: `isValid`, `hasNoViolations`, `hasViolation`, `exercised`.
- Fixture matchers: `conformsToResponse`, `conformsToRequestBody`,
  `conformsToSchema` for plain JSON values and JSON strings.
- `describeValidationFailures` and `writeCoverageReport` helpers.
