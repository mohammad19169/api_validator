# api_validator_test

Test helpers for [api_validator](https://pub.dev/packages/api_validator):
fail tests whose HTTP traffic breaks your OpenAPI spec, check JSON fixtures
against the spec, and measure which endpoints your tests never touched.

Works with `package:test` and `flutter_test`.

## Install

```sh
dart pub add dev:api_validator_test
# plus an adapter for your HTTP client:
dart pub add dev:api_validator_dio   # or api_validator_http
```

## 1. Fail tests automatically

```dart
import 'package:api_validator_dio/api_validator_dio.dart';
import 'package:api_validator_test/api_validator_test.dart';
import 'package:test/test.dart';

void main() {
  final checker = useApiValidatorFromFile('openapi.yaml');
  final dio = Dio()..addApiValidator(checker);

  test('shows the profile', () async {
    await ProfileRepository(dio).load();
  });
}
```

`useApiValidator(checker)` (or `useApiValidatorFromFile(path)`) registers:

- `setUp`: clears the results of the previous test (coverage is kept).
- `tearDown`: fails the test if errors were recorded during it, with a
  message like:

  ```text
  The HTTP traffic of this test does not match the OpenAPI spec (1 violation):
  ✗ GET /users/{id} -> 200
      error: [response.body] $.address.zip: expected string, got integer (GET /users/{id})
  ```

- `tearDownAll`: writes the coverage of this test file to
  `build/api_validator/coverage/coverage-<unique>.json`.

Options: `failOnErrors` (default `true`), `failOnWarnings` (default
`false`), `coverageDirectory` (`null` to disable).

## 2. Check fixtures without any HTTP client

```dart
final spec = OpenApiSpec.fromFileSync('openapi.yaml');

test('fixtures are up to date', () {
  expect(File('test/fixtures/pet.json').readAsStringSync(),
      conformsToResponse(spec, 'getPet'));             // 200 by default
  expect(errorJson, conformsToResponse(spec, 'getPet', status: 404));
  expect({'name': 'Rex'}, conformsToRequestBody(spec, 'createPet'));
  expect(ownerJson, conformsToSchema(spec, 'Owner'));
});
```

Values may be decoded JSON (`Map`, `List`, ...) or JSON strings. Failures
list every problem with its JSON path. Operations are referenced by
`operationId` or `'METHOD /path'`. Pass `mode: ValidationMode.lenient` to
tolerate undeclared properties.

## 3. Assert on violations and coverage

```dart
expect(checker, isValid);       // no errors (warnings allowed)
expect(checker, hasNoViolations);    // no errors and no warnings
expect(result, hasViolation(type: UndeclaredStatus));
expect(checker, hasViolation(jsonPath: r'$.items[0].price', severity: Severity.error));
expect(checker, hasViolation(kind: 'missing-parameter', message: 'X-Request-Id'));

expect(checker, exercised('getPet'));               // called at least once
expect(checker, exercised('getPet', status: 404));  // and returned 404
expect(checker.coverage, exercised('DELETE /pets/{id}', status: '2XX'));
```

`isValid`, `hasNoViolations` and `hasViolation` accept a
`ApiValidator`, a `ValidationResult` or an `Iterable<Violation>`.
`exercised` accepts a `ApiValidator` or a `CoverageReport`.

## 4. Coverage across all test files

Every test file runs in its own isolate and writes its own coverage file.
Merge them, and optionally enforce a minimum, with the CLI from
`api_validator`:

```sh
dart run api_validator coverage build/api_validator/coverage
```

Or in Dart, with `CoverageReport.fromJson` and `CoverageReport.merge`.

## API summary

| API | Purpose |
| --- | --- |
| `useApiValidator(checker, {...})` | Wire a checker into the current suite. |
| `useApiValidatorFromFile(path, {options, ...})` | Same, loading the spec from disk. |
| `describeValidationFailures(checker, {...})` | The failure message used by the `tearDown`, or `null`. |
| `writeCoverageReport(report, [directory])` | Write a coverage file. |
| `isValid`, `hasNoViolations` | Matchers for "nothing broke". |
| `hasViolation({type, kind, location, jsonPath, message, severity})` | Matcher for a specific violation. |
| `exercised(operation, {status})` | Coverage matcher. |
| `conformsToResponse`, `conformsToRequestBody`, `conformsToSchema` | Fixture matchers. |

Everything from `api_validator` is re-exported.

## Limitations

- `useApiValidatorFromFile` and coverage files need `dart:io`. In browser
  tests, load the spec with `OpenApiSpec.fromString`. Coverage writing is
  skipped there.
- Call `useApiValidator` while tests are being declared (in `main` or a
  `group`), not inside a running test.

## License

MIT
