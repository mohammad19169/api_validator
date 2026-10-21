// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:typed_data';

import 'package:api_validator_dio/api_validator_dio.dart';
import 'package:dio/dio.dart';

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
              schema:
                type: object
                required: [id, name]
                properties:
                  id: {type: integer}
                  name: {type: string}
''';

/// A stand-in backend, like the mock adapters used in tests. Its response
/// is stale: `name` was renamed to `petName`.
class StaleMockAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({'id': 1, 'petName': 'Rex'}),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<void> main() async {
  final checker = ApiValidator(OpenApiSpec.fromString(specYaml));

  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = StaleMockAdapter()
    ..addApiValidator(checker);

  await dio.get<Object?>('/pets/1');

  // ✗ GET /pets/{id} -> 200
  //     error: [response.body] $.name: required property "name" is missing
  //     error: [response.body] $.petName: property "petName" is not declared in
  //            the schema
  print(ValidationReporter.text(checker.results));
  print(checker.coverage.toText());
}
