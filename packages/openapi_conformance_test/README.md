# openapi_conformance_test

Test helpers for [openapi_conformance](https://pub.dev/packages/openapi_conformance):
fail tests whose HTTP traffic breaks your OpenAPI spec, check JSON fixtures
against the spec, and measure which endpoints your tests never touched.

Works with `package:test` and `flutter_test`.

## Install

```sh
dart pub add dev:openapi_conformance_test
# plus an adapter for your HTTP client:
dart pub add dev:openapi_conformance_dio   # or openapi_conformance_http
```

## 1. Fail tests automatically

```dart
import 'package:openapi_conformance_dio/openapi_conformance_dio.dart';
import 'package:openapi_conformance_test/openapi_conformance_test.dart';
import 'package:test/test.dart';

void main() {
  final checker = useConformanceFromFile('openapi.yaml');
  final dio = Dio()..addConformance(checker);

  test('shows the profile', () async {
    await ProfileRepository(dio).load();
  });
}
```

`useConformance(checker)` (or `useConformanceFromFile(path)`) registers:

- `setUp`: clears the results of the previous test (coverage is kept).
- `tearDown`: fails the test if errors were recorded during it, with a
  message like:

  ```text
  The HTTP traffic of this test does not match the OpenAPI spec (1 violation):
  ✗ GET /users/{id} -> 200
      error: [response.body] $.address.zip: expected string, got integer (GET /users/{id})
  ```

- `tearDownAll`: writes the coverage of this test file to
  `build/openapi_conformance/coverage/coverage-<unique>.json`.

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
`operationId` or `'METHOD /path'`. Pass `mode: ConformanceMode.lenient` to
tolerate undeclared properties.

## 3. Assert on violations and coverage

```dart
expect(checker, isConforming);       // no errors (warnings allowed)
expect(checker, hasNoViolations);    // no errors and no warnings
expect(result, hasViolation(type: UndeclaredStatus));
expect(checker, hasViolation(jsonPath: r'$.items[0].price', severity: Severity.error));
expect(checker, hasViolation(kind: 'missing-parameter', message: 'X-Request-Id'));

expect(checker, exercised('getPet'));               // called at least once
expect(checker, exercised('getPet', status: 404));  // and returned 404
expect(checker.coverage, exercised('DELETE /pets/{id}', status: '2XX'));
```

`isConforming`, `hasNoViolations` and `hasViolation` accept a
`ConformanceChecker`, a `ConformanceResult` or an `Iterable<Violation>`.
`exercised` accepts a `ConformanceChecker` or a `CoverageReport`.

## 4. Coverage across all test files

Every test file runs in its own isolate and writes its own coverage file.
Merge them, and optionally enforce a minimum, with the CLI from
`openapi_conformance`:

```sh
dart run openapi_conformance coverage build/openapi_conformance/coverage
```

Or in Dart, with `CoverageReport.fromJson` and `CoverageReport.merge`.

## API summary

| API | Purpose |
| --- | --- |
| `useConformance(checker, {...})` | Wire a checker into the current suite. |
| `useConformanceFromFile(path, {options, ...})` | Same, loading the spec from disk. |
| `describeConformanceFailures(checker, {...})` | The failure message used by the `tearDown`, or `null`. |
| `writeCoverageReport(report, [directory])` | Write a coverage file. |
| `isConforming`, `hasNoViolations` | Matchers for "nothing broke". |
| `hasViolation({type, kind, location, jsonPath, message, severity})` | Matcher for a specific violation. |
| `exercised(operation, {status})` | Coverage matcher. |
| `conformsToResponse`, `conformsToRequestBody`, `conformsToSchema` | Fixture matchers. |

Everything from `openapi_conformance` is re-exported.

## Limitations

- `useConformanceFromFile` and coverage files need `dart:io`. In browser
  tests, load the spec with `OpenApiSpec.fromString`. Coverage writing is
  skipped there.
- Call `useConformance` while tests are being declared (in `main` or a
  `group`), not inside a running test.

## License

MIT
