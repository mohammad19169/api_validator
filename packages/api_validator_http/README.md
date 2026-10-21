# api_validator_http

A drop-in [`package:http`](https://pub.dev/packages/http) client that checks
every request and response against your OpenAPI spec.

In plain words: wrap your client (or the `MockClient` your tests already
use) and you are told whenever a request, a mock or a server response no
longer matches the API contract: a wrong type, a missing field, an
undeclared status code or a bad parameter.

Built on [api_validator](https://pub.dev/packages/api_validator)
(OpenAPI 3.0 and 3.1).

## Install

```sh
dart pub add dev:api_validator_http
# optional, for test matchers and automatic test failures:
dart pub add dev:api_validator_test
```

## Quick start

```dart
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:api_validator_http/api_validator_http.dart';

final checker = ApiValidator(OpenApiSpec.fromFileSync('openapi.yaml'));

final client = ApiValidatorClient(
  checker,
  inner: MockClient((request) async => http.Response('{"id": "7"}', 200)),
);

await client.get(Uri.parse('https://api.example.com/pets/7'));

print(ValidationReporter.text(checker.results));
// ✗ GET /pets/{id} -> 200
//     error: [response.body] $.id: expected integer, got string (GET /pets/{id})
//     error: [response.body] $.name: required property "name" is missing (GET /pets/{id})
```

Leave out `inner` to wrap a real `http.Client()`.

## In tests

```dart
import 'package:api_validator_http/api_validator_http.dart';
import 'package:api_validator_test/api_validator_test.dart';
import 'package:test/test.dart';

void main() {
  final checker = useApiValidatorFromFile('openapi.yaml');

  test('creates a pet', () async {
    final client = ApiValidatorClient(checker, inner: MockClient(handler));
    await PetApi(client).create(name: 'Rex');
  }); // fails here if request or mocked response break the spec
}
```

## API

```dart
ApiValidatorClient(
  ApiValidator checker, {
  http.Client? inner,                          // defaults to http.Client()
  bool throwOnViolation = false,               // throw ApiValidationException
  bool Function(http.BaseRequest request)? skip, // send without checking
})
```

`ApiValidatorClient` is a regular `http.BaseClient`, so it works anywhere a
`Client` is accepted (Chopper, retry wrappers, generated API clients, ...).
Everything from `api_validator` is re-exported.

### Behaviour

- The response body is read once, checked, and returned to you unchanged
  with status, headers, reason phrase, content length and redirect
  information preserved.
- `text/event-stream` responses are passed through without buffering; only
  their status and headers are checked.
- `Request` bodies are checked as JSON, form-urlencoded or text according
  to the content type. `MultipartRequest`s are reported as having a body but
  are not schema-validated. `StreamedRequest` bodies cannot be read without
  consuming them and are not checked.
- When the inner client throws, a request-only exchange is recorded and the
  original exception is rethrown.
- `close()` closes the inner client.

### `throwOnViolation`

Off by default: violations are recorded and you decide when to fail
(`checker.verify()`, or `useApiValidator` from `api_validator_test`).
When on, a `ApiValidationException` is thrown after the exchange is recorded.

## FAQ

**Can I use it in my app?** Yes. Use
`ValidatorOptions.runtime()` and set `checker.enabled = kDebugMode` so
nothing runs in release builds. Violations go to the debug log.

**Does it work on the web?** Yes. Load the spec with
`OpenApiSpec.fromString` there, since files cannot be read.

## License

MIT
