# api_validator

[![pub package](https://img.shields.io/pub/v/api_validator.svg)](https://pub.dev/packages/api_validator)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Make your API tests stop lying.** `api_validator` checks every HTTP
request your app sends and every response it receives, mocked, recorded or
real, against your OpenAPI 3.0 / 3.1 spec.

Your mock returns `{"zip": 12345}` but the real API sends `"zip": "12345"`?
Your tests pass and the app crashes in production. With this package the test
fails instead:

```
✗ GET /users/{id} -> 200
    error: [response.body] $.address.zip: expected string, got integer (GET /users/{id})
```

## What it does for you

| | |
|---|---|
| **Catches stale mocks** | Mock responses that no longer match the spec fail your tests. |
| **Catches bad requests** | Missing required fields, wrong types, unknown endpoints, missing auth. |
| **Works with your existing tools** | http_mock_adapter, nock, MockClient, mocktail, recorded cassettes, real servers. It watches, it does not replace. |
| **API coverage report** | "You tested 34 of 50 endpoints and never tested a 404." |
| **Generates test data** | Schema-valid fake responses that never go stale. |
| **Breaks your parsers on purpose** | Edge cases: nulls, missing optionals, empty lists, unknown enum values. |
| **Lints saved fixtures and HAR files** | A CLI that checks JSON files without running tests. |
| **Warns when the API changes** | Diff two spec versions and see the breaking changes for your app. |
| **CI ready** | JUnit XML, JSON and GitHub Actions annotations. |
| **Debug overlay** | See failing API calls inside your running app (separate package). |

## Packages

| Package | Use it for |
|---|---|
| `api_validator` | Core: spec loading, validation, coverage, fake data, diff, CLI. Pure Dart, all platforms. |
| [`api_validator_dio`](https://pub.dev/packages/api_validator_dio) | A dio interceptor. |
| [`api_validator_http`](https://pub.dev/packages/api_validator_http) | A `package:http` client wrapper. |
| [`api_validator_test`](https://pub.dev/packages/api_validator_test) | Matchers and one-line test setup with coverage files. |
| [`api_validator_flutter`](https://pub.dev/packages/api_validator_flutter) | In-app debug overlay. |

## Install

```sh
dart pub add dev:api_validator
# plus the adapter for your HTTP client, for example:
dart pub add dev:api_validator_dio dev:api_validator_test
```

## Quick start

With dio and the test helpers:

```dart
import 'package:dio/dio.dart';
import 'package:api_validator_dio/api_validator_dio.dart';
import 'package:api_validator_test/api_validator_test.dart';
import 'package:test/test.dart';

void main() {
  // Fails any test that produces a spec violation and writes coverage.
  final checker = useApiValidatorFromFile('openapi.yaml');

  late Dio dio;
  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.com/v1'))
      ..httpClientAdapter = MyMockAdapter() // whatever you use today
      ..interceptors.add(ApiValidatorInterceptor(checker));
  });

  test('loads the profile', () async {
    await UserRepository(dio).load(42);
    expect(checker, exercised('GET /users/{id}', status: 200));
  });
}
```

Without any adapter, using the core directly:

```dart
final checker = ApiValidator(await OpenApiSpec.fromFile('openapi.yaml'));

final result = checker.check(Exchange(
  request: ExchangeRequest(
    method: 'GET',
    uri: Uri.parse('https://api.example.com/v1/users/42'),
  ),
  response: ExchangeResponse(
    statusCode: 200,
    headers: {'content-type': 'application/json'},
    body: '{"id": 42, "name": "Ada"}',
  ),
));

print(result.isValid); // true
checker.verify(); // throws ApiValidationException if any error was recorded
```

## What is checked

**Requests**
- the path and method exist in the spec (`unknown-operation`, `method-not-allowed`)
- path, query, header and cookie parameters: presence, type, enum, format,
  min/max, with OpenAPI serialization styles (`form`, `simple`, `deepObject`,
  `spaceDelimited`, `pipeDelimited`, exploded or not)
- the request body: required, content type, schema (JSON and
  `application/x-www-form-urlencoded`)
- `readOnly` properties that must not be sent
- credentials for the operation's security requirements (warning)
- calls to deprecated operations (warning)

**Responses**
- the status code is declared (exact, `4XX` range or `default`)
- required response headers and their schemas
- the content type and the body schema, including `writeOnly` properties

**Schemas**
`type` (including 3.1 type arrays), `nullable`, `enum`, `const`, `format`,
`minLength`/`maxLength`/`pattern`, `minimum`/`maximum`/`exclusive*` (3.0 and
3.1 forms), `multipleOf`, `items`/`prefixItems`/`contains`, `min/maxItems`,
`uniqueItems`, `properties`/`required`/`additionalProperties`/
`patternProperties`/`propertyNames`/`dependentRequired`, `allOf`/`anyOf`/
`oneOf`/`not`, `if`/`then`/`else`, `discriminator` with `mapping`, recursive
`$ref`s. Built-in formats: `date-time`, `date`, `time`, `email`, `uuid`,
`uri`, `uri-reference`, `hostname`, `ipv4`, `ipv6`, `byte`, `int32`, `int64`.
Add your own with `customFormats`.

Every violation tells you **where** (`response.body`), **what** (`$.address.zip`)
and **why** (`expected string, got integer`).

## Strict and lenient mode

```dart
ApiValidator(spec, options: ValidatorOptions(
  mode: ValidationMode.lenient,           // undeclared fields become warnings
  unmatchedRequests: UnmatchedPolicy.warning,
  ignoreOperations: ['healthCheck', 'GET /metrics'],
  ignorePaths: [RegExp(r'^/v1/internal/')],
  validateFormats: true,
  customFormats: {'iban': isValidIban},
));
```

| Finding | strict | lenient |
|---|---|---|
| Property not declared in the schema | error | warning |
| Status code not declared | error | warning |
| `readOnly` sent / `writeOnly` returned | error | warning |
| Everything else (types, required, enum, ...) | error | error |

## Handling violations

`Violation` is a sealed class, so you can switch over it exhaustively:

```dart
for (final violation in checker.violations) {
  switch (violation) {
    case SchemaMismatch(:final error):
      print('Bad field ${error.path}: ${error.message}');
    case UndeclaredStatus(:final statusCode, :final declaredStatuses):
      print('Got $statusCode, spec declares $declaredStatuses');
    case UnknownOperation(:final method, :final path):
      print('$method $path is not in the spec');
    default:
      print(violation);
  }
}
```

## API coverage

```dart
print(checker.coverage.toText());
```

```
API coverage: 34/50 operations (68.0%), 61/120 responses (50.8%)
  ✗ DELETE /orders/{id}  never called
  ~ GET /users/{id}  untested responses: 404, default
```

Test files run in separate isolates. `useApiValidator` (from
`api_validator_test`) writes one coverage file per test file. Merge them
and enforce a minimum in CI:

```sh
dart run api_validator coverage --min-operations 80
```

## Fake data and edge cases

```dart
final fake = FakeData(spec, seed: 1);
final user = fake.response('getUser');           // valid response body
final body = fake.requestBody('POST /users');    // valid request body

for (final edge in EdgeCases(spec).forResponse('getUser')) {
  // "nullable $.address set to null", "array $.tags empty", ...
  expect(() => User.fromJson(edge.value as Map<String, dynamic>),
      returnsNormally, reason: edge.description);
}
```

## Spec diff

```dart
final diff = SpecDiff.compare(oldSpec, newSpec);
for (final change in diff.breaking) {
  print(change); // breaking: response property $.address.zip changed type
}
```

## Command line

```sh
# Check saved fixtures and HAR recordings without running tests
dart run api_validator check --spec openapi.yaml \
  --fixture test/fixtures/user.json=getUser:200 --har session.har

# Configure once in api_validator.yaml, then just run
dart run api_validator check --reporter github

# What breaks for the app if the backend ships the new spec?
dart run api_validator diff openapi.old.yaml openapi.yaml

# Merge coverage files from all test files and enforce thresholds
dart run api_validator coverage --min-operations 80 --min-responses 60
```

`api_validator.yaml`:

```yaml
spec: openapi.yaml
mode: strict
fixtures:
  - path: test/fixtures/user.json
    operation: getUser
    status: 200
  - glob: test/fixtures/orders/*.json
    operation: GET /orders/{id}
    status: 200
har:
  - recordings/checkout.har
```

Exit codes: `0` conforming, `1` violations or thresholds missed, `2` usage or
configuration error.

## Reports for CI

```dart
ValidationReporter.text(checker.results);
ValidationReporter.json(checker.results, coverage: checker.coverage);
ValidationReporter.junit(checker.results);   // most CI systems render it
ValidationReporter.github(checker.results);  // inline GitHub annotations
```

## Running inside the app (debug builds)

```dart
final checker = ApiValidator(
  OpenApiSpec.fromString(await rootBundle.loadString('assets/openapi.yaml')),
  options: const ValidatorOptions.runtime(), // lenient, logged, bounded
)..enabled = kDebugMode;
```

Violations go to the `dart:developer` log. Add
`api_validator_flutter` to see them in an on-screen overlay. Users of
release builds never see anything.

## Limitations

- OpenAPI 2.0 (Swagger) is not supported. Convert it to OpenAPI 3 first.
- Only local `$ref`s (`#/...`). Bundle multi-file specs first, for example with
  `redocly bundle`.
- `multipart/*` and binary bodies are checked for presence and content type,
  not schema.
- Regular expressions use Dart's `RegExp` (ECMAScript-like), so a few exotic
  pattern features may differ.

## License

MIT
