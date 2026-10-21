import 'package:api_validator_test/api_validator_test.dart';
import 'package:test/test.dart';

const specYaml = r'''
openapi: 3.0.3
info: {title: Pet Store, version: '1'}
servers:
  - url: https://api.example.com
paths:
  /pets/{id}:
    get:
      operationId: getPet
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        '200':
          description: A pet
          content:
            application/json:
              schema: {$ref: '#/components/schemas/Pet'}
        '404':
          description: Not found
components:
  schemas:
    Pet:
      type: object
      required: [id, name]
      properties:
        id: {type: integer}
        name: {type: string}
''';

/// The JSON a test fixture or mock returns for `GET /pets/1`.
const petFixture = '{"id": 1, "name": "Rex"}';

void main() {
  final spec = OpenApiSpec.fromString(specYaml);

  // Fails any test below whose traffic breaks the spec, and writes coverage
  // to build/api_validator/coverage when the suite ends.
  final checker = useApiValidator(ApiValidator(spec));

  test('the fixture matches the spec', () {
    expect(petFixture, conformsToResponse(spec, 'getPet'));
    expect('{"id": 1}', isNot(conformsToResponse(spec, 'getPet')));
  });

  test('traffic is checked', () {
    // Normally an adapter (api_validator_dio or
    // api_validator_http) feeds the checker for you.
    checker.check(
      Exchange(
        request: ExchangeRequest(
          method: 'GET',
          uri: Uri.parse('https://api.example.com/pets/1'),
        ),
        response: ExchangeResponse(statusCode: 200, body: petFixture),
      ),
    );
    expect(checker, isValid);
    expect(checker, exercised('getPet', status: 200));
  });
}
