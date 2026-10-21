import 'dart:convert';

import 'package:api_validator_http/api_validator_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _spec = r'''
openapi: 3.0.3
info: {title: Test, version: '1'}
servers:
  - url: https://api.example.com
paths:
  /users/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                required: [id, name]
                properties:
                  id: {type: integer}
                  name: {type: string}
  /users:
    post:
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [name]
              properties:
                name: {type: string}
      responses:
        '201': {description: created}
  /avatars:
    post:
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema: {type: object}
      responses:
        '204': {description: stored}
  /events:
    get:
      responses:
        '200':
          description: stream
          content:
            text/event-stream:
              schema: {type: string}
''';

const _jsonHeaders = {'content-type': 'application/json'};

void main() {
  final spec = OpenApiSpec.fromString(_spec);
  late ApiValidator checker;

  setUp(() => checker = ApiValidator(spec));

  ApiValidatorClient clientFor(
    MockClientHandler handler, {
    bool throwOnViolation = false,
    bool Function(http.BaseRequest request)? skip,
  }) => ApiValidatorClient(
    checker,
    inner: MockClient(handler),
    throwOnViolation: throwOnViolation,
    skip: skip,
  );

  final usersUrl = Uri.parse('https://api.example.com/users/1');

  test('checks responses and returns the body unchanged', () async {
    final client = clientFor(
      (_) async => http.Response(
        '{"id": 1, "name": "Ada"}',
        200,
        headers: _jsonHeaders,
        reasonPhrase: 'OK',
      ),
    );
    final response = await client.get(usersUrl);
    expect(jsonDecode(response.body), {'id': 1, 'name': 'Ada'});
    expect(response.reasonPhrase, 'OK');
    expect(response.headers['content-type'], 'application/json');
    expect(checker.results.single.violations, isEmpty);
  });

  test('records violations from MockClient responses', () async {
    final client = clientFor((_) async => http.Response('{"id": "x"}', 200));
    await client.get(usersUrl);
    expect([
      for (final v in checker.errors) v.jsonPath,
    ], containsAll([r'$.id', r'$.name']));
  });

  test('validates JSON request bodies', () async {
    final client = clientFor((_) async => http.Response('', 201));
    await client.post(
      Uri.parse('https://api.example.com/users'),
      headers: _jsonHeaders,
      body: jsonEncode({'name': 42}),
    );
    expect(checker.errors.single.jsonPath, r'$.name');
    await client.post(Uri.parse('https://api.example.com/users'));
    expect(checker.errors.last, isA<MissingBody>());
  });

  test('multipart requests count as a present body', () async {
    final client = clientFor((_) async => http.Response('', 204));
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('https://api.example.com/avatars'),
          )
          ..fields['user'] = '1'
          ..files.add(
            http.MultipartFile.fromBytes('file', [1, 2], filename: 'a.png'),
          );
    await client.send(request);
    final result = checker.results.single;
    expect(result.violations, isEmpty);
    expect(result.exchange.request.body, {'user': '1', 'file': 'a.png'});
  });

  test('throwOnViolation throws after recording', () async {
    final client = clientFor(
      (_) async => http.Response('{}', 200, headers: _jsonHeaders),
      throwOnViolation: true,
    );
    await expectLater(
      client.get(usersUrl),
      throwsA(isA<ApiValidationException>()),
    );
    expect(checker.errors, isNotEmpty);
  });

  test('inner exceptions are recorded and rethrown', () async {
    final client = clientFor(
      (_) async => throw http.ClientException('offline'),
    );
    await expectLater(
      client.get(Uri.parse('https://api.example.com/users/abc')),
      throwsA(isA<http.ClientException>()),
    );
    final result = checker.results.single;
    expect(result.exchange.response, isNull);
    expect(result.errors.single, isA<InvalidParameter>());
  });

  test('event streams are not buffered', () async {
    final inner = MockClient.streaming(
      (request, _) async => http.StreamedResponse(
        Stream.fromIterable([utf8.encode('data: 1\n\n')]),
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final client = ApiValidatorClient(checker, inner: inner);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://api.example.com/events')),
    );
    expect(await response.stream.bytesToString(), 'data: 1\n\n');
    expect(checker.results.single.exchange.response?.body, isNull);
  });

  test('skip and disabled checker bypass checks', () async {
    final skipping = clientFor(
      (_) async => http.Response('{}', 200),
      skip: (request) => request.url.path.startsWith('/users'),
    );
    await skipping.get(usersUrl);
    expect(checker.results, isEmpty);

    checker.enabled = false;
    final client = clientFor(
      (_) async => http.Response('{}', 200),
      throwOnViolation: true,
    );
    expect((await client.get(usersUrl)).statusCode, 200);
    expect(checker.results, isEmpty);
  });

  test('close closes the inner client', () {
    var closed = false;
    final client = ApiValidatorClient(
      checker,
      inner: _ClosingClient(() => closed = true),
    );
    client.close();
    expect(closed, isTrue);
  });
}

class _ClosingClient extends http.BaseClient {
  _ClosingClient(this.onClose);

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() => onClose();
}
