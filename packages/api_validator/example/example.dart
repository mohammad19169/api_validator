// Checks a few recorded exchanges against a small spec and prints the
// results and the API coverage.
//
// Run with: dart run example/example.dart
import 'package:api_validator/api_validator.dart';

const spec = '''
openapi: 3.0.3
info: { title: Users, version: 1.0.0 }
servers: [{ url: https://api.example.com/v1 }]
paths:
  /users/{id}:
    get:
      operationId: getUser
      parameters:
        - { name: id, in: path, required: true, schema: { type: integer } }
      responses:
        '200':
          description: The user
          content:
            application/json:
              schema: { \$ref: '#/components/schemas/User' }
        '404': { description: Not found }
  /users:
    post:
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema: { \$ref: '#/components/schemas/User' }
      responses:
        '201': { description: Created }
components:
  schemas:
    User:
      type: object
      required: [id, name]
      properties:
        id: { type: integer, readOnly: true }
        name: { type: string }
        address:
          type: object
          properties:
            zip: { type: string }
''';

void main() {
  final checker = ApiValidator(OpenApiSpec.fromString(spec));

  // A mock that went stale: the backend now sends `zip` as a string.
  final stale = checker.check(
    Exchange(
      request: ExchangeRequest(
        method: 'GET',
        uri: Uri.parse('https://api.example.com/v1/users/42'),
      ),
      response: ExchangeResponse(
        statusCode: 200,
        headers: {'content-type': 'application/json'},
        body: '{"id": 42, "name": "Ada", "address": {"zip": 12345}}',
      ),
    ),
  );
  print(stale);
  // ✗ GET /users/{id} -> 200
  //     error: [response.body] $.address.zip: expected string, got integer ...

  // The app forgot the required body.
  print(
    checker.check(
      Exchange(
        request: ExchangeRequest(
          method: 'POST',
          uri: Uri.parse('https://api.example.com/v1/users'),
        ),
        response: ExchangeResponse(statusCode: 201),
      ),
    ),
  );

  // Pattern-match on violation types to react to specific problems.
  for (final violation in checker.violations) {
    switch (violation) {
      case SchemaMismatch(:final error):
        print('Fix the field at ${error.path}');
      case MissingBody():
        print('Send a body to ${violation.operation}');
      default:
        print(violation);
    }
  }

  print(checker.coverage.toText());
  // API coverage: 2/2 operations (100.0%), 2/3 responses (66.7%)
  //   ~ GET /users/{id}  untested responses: 404
}
