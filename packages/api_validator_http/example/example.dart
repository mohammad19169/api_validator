// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:api_validator_http/api_validator_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const specYaml = r'''
openapi: 3.0.3
info: {title: Pet Store, version: '1'}
servers:
  - url: https://api.example.com
paths:
  /pets:
    post:
      operationId: createPet
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: {type: string, minLength: 1}
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema:
                type: object
                required: [id, name]
                properties:
                  id: {type: integer}
                  name: {type: string}
''';

Future<void> main() async {
  final checker = ApiValidator(OpenApiSpec.fromString(specYaml));

  // In tests, wrap a MockClient. In an app, leave `inner` out to wrap a
  // real http.Client.
  final client = ApiValidatorClient(
    checker,
    inner: MockClient(
      (request) async => http.Response(
        jsonEncode({'id': '7', 'name': 'Rex'}),
        201,
        headers: {'content-type': 'application/json'},
      ),
    ),
  );

  final response = await client.post(
    Uri.parse('https://api.example.com/pets'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({'name': ''}),
  );
  print('Status: ${response.statusCode}, body: ${response.body}');

  // ✗ POST /pets -> 201
  //     error: [request.body] $.name: expected at least 1 characters, got 0
  //     error: [response.body] $.id: expected integer, got string
  print(ValidationReporter.text(checker.results));
  client.close();
}
