# api_validator_dio

A [dio](https://pub.dev/packages/dio) interceptor that checks every request
your app sends, and every response it gets back, against your OpenAPI spec.

In plain words: your tests keep using whatever mocks they use today. This
interceptor watches the traffic and tells you when a mock, a request or a
real server response no longer matches the API contract — a wrong type, a
missing field, an undeclared status code, a bad query parameter.

Built on [api_validator](https://pub.dev/packages/api_validator)
(OpenAPI 3.0 and 3.1).

## Install

```sh
dart pub add dev:api_validator_dio
# optional, for test matchers and automatic test failures:
dart pub add dev:api_validator_test
```

Add it as a regular dependency instead if you also want to check traffic
inside your running app in debug mode.

## Quick start

```dart
import 'package:dio/dio.dart';
import 'package:api_validator_dio/api_validator_dio.dart';

final checker = ApiValidator(OpenApiSpec.fromFileSync('openapi.yaml'));

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
  ..addApiValidator(checker);

await dio.get('/pets/1');

print(checker.isValid);                       // false if anything broke
print(ValidationReporter.text(checker.results));  // what broke, field by field
print(checker.coverage.toText());                  // which endpoints were never called
```

Example output:

```text
✗ GET /pets/{id} -> 200
    error: [response.body] $.name: required property "name" is missing (GET /pets/{id})
    error: [response.body] $.petName: property "petName" is not declared in the schema (GET /pets/{id})
1 exchange checked, 2 errors, 0 warnings
```

## In tests

Combine it with `api_validator_test` so each test fails automatically
when its traffic breaks the spec:

```dart
import 'package:api_validator_dio/api_validator_dio.dart';
import 'package:api_validator_test/api_validator_test.dart';
import 'package:test/test.dart';

void main() {
  final checker = useApiValidatorFromFile('openapi.yaml');
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
      ..httpClientAdapter = myMockAdapter // http_mock_adapter, custom, ...
      ..addApiValidator(checker);
  });

  test('loads a pet', () async {
    await PetRepository(dio).load(1);
  }); // fails here if the mocked response does not match the spec
}
```

## Works with your existing mocks

Dio runs interceptors around the `HttpClientAdapter`, so responses from
`http_mock_adapter`, a hand-written fake adapter, a recorded cassette or a
real server are all checked the same way. You do not need to change how you
mock.

## API

| API | Purpose |
| --- | --- |
| `ApiValidatorInterceptor(checker, {throwOnViolation})` | The interceptor. Add it to `dio.interceptors`. |
| `dio.addApiValidator(checker, {throwOnViolation})` | Shortcut that adds the interceptor and returns the `Dio`. |
| `exchangeFromDio(requestOptions, [response])` | Converts dio objects into an `Exchange` for manual checks. |

Everything from `api_validator` (`ApiValidator`, `OpenApiSpec`,
`ValidatorOptions`, reporters, ...) is re-exported.

### `throwOnViolation`

By default violations are only recorded. Your app's error handling cannot
accidentally swallow them, and you decide when to fail (for example with
`checker.verify()` or the `api_validator_test` helpers).

With `throwOnViolation: true`, a non-conforming exchange becomes a
`DioException` whose `error` is a `ApiValidationException` and whose
`response` is the original response.

### What is checked

- Request: path, query, header and cookie parameters, required credentials
  (as warnings), and the body (JSON, form-urlencoded and text).
- Response: status code, required headers, and the body.
- `FormData` bodies are reported as present but are not schema-validated.
- Error responses (4xx/5xx) are checked through `onError`. Connection
  failures are recorded as request-only exchanges.

### Interceptor order

Add the interceptor after interceptors that change the request (auth, base
URL rewriting, headers), so the checker sees what is actually sent.

### Debug builds

```dart
final checker = ApiValidator(spec, options: const ValidatorOptions.runtime())
  ..enabled = kDebugMode;
dio.addApiValidator(checker);
```

Violations are then logged to the debug console, never shown to users, and
nothing runs in release builds. Pair it with `api_validator_flutter`
for an on-screen inspector.

## FAQ

**Does it slow requests down?** Checking is synchronous and fast (schema
validation of the decoded body); in tests it is negligible.

**Streamed responses (`ResponseType.stream`)?** The body is not available to
interceptors, so only status and headers are checked.

**My spec uses external `$ref`s.** Bundle it into a single file first
(`redocly bundle`, `swagger-cli bundle`).

## License

MIT
