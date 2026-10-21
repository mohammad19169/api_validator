import 'dart:convert';
import 'dart:typed_data';

import 'package:api_validator_dio/api_validator_dio.dart';
import 'package:dio/dio.dart';
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
        '404':
          description: missing
          content:
            application/json:
              schema:
                type: object
                required: [message]
                properties:
                  message: {type: string}
  /uploads:
    post:
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema: {type: object}
          application/octet-stream:
            schema: {type: string, format: binary}
      responses:
        '201': {description: created}
''';

typedef _Handler = ResponseBody Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final _Handler handler;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  final spec = OpenApiSpec.fromString(_spec);
  late ApiValidator checker;

  Dio dioWith(_Handler handler, {bool throwOnViolation = false}) =>
      Dio(BaseOptions(baseUrl: 'https://api.example.com'))
        ..httpClientAdapter = _FakeAdapter(handler)
        ..addApiValidator(checker, throwOnViolation: throwOnViolation);

  setUp(() => checker = ApiValidator(spec));

  test('records a conforming exchange', () async {
    final dio = dioWith((_) => _json({'id': 1, 'name': 'Ada'}));
    final response = await dio.get<Object?>('/users/1');
    expect(response.statusCode, 200);
    expect(checker.results.single.violations, isEmpty);
    expect(checker.results.single.operation?.key, 'GET /users/{id}');
  });

  test('records schema violations from mocked responses', () async {
    final dio = dioWith((_) => _json({'id': 'one'}));
    await dio.get<Object?>('/users/1');
    final paths = [for (final v in checker.errors) v.jsonPath];
    expect(paths, containsAll([r'$.id', r'$.name']));
  });

  test('checks error responses delivered through onError', () async {
    final dio = dioWith((_) => _json({'message': 'gone'}, status: 404));
    await expectLater(
      dio.get<Object?>('/users/2'),
      throwsA(isA<DioException>()),
    );
    expect(checker.results.single.responseKey, '404');
    expect(checker.results.single.violations, isEmpty);

    final failing = dioWith((_) => _json({'oops': true}, status: 500));
    await expectLater(
      failing.get<Object?>('/users/2'),
      throwsA(isA<DioException>()),
    );
    expect(checker.errors.single, isA<UndeclaredStatus>());
  });

  test('records request-only exchanges for connection errors', () async {
    final dio = dioWith(
      (options) => throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      ),
    );
    await expectLater(
      dio.get<Object?>('/users/abc'),
      throwsA(isA<DioException>()),
    );
    final result = checker.results.single;
    expect(result.exchange.response, isNull);
    expect(result.errors.single, isA<InvalidParameter>());
  });

  test('throwOnViolation rejects non-conforming responses', () async {
    final dio = dioWith((_) => _json({'id': 1}), throwOnViolation: true);
    final error = await dio
        .get<Object?>('/users/1')
        .then<DioException?>(
          (_) => null,
          onError: (Object e) => e as DioException,
        );
    expect(error, isNotNull);
    expect(error!.error, isA<ApiValidationException>());
    expect(error.response?.statusCode, 200);

    final ok = dioWith(
      (_) => _json({'id': 1, 'name': 'a'}),
      throwOnViolation: true,
    );
    expect((await ok.get<Object?>('/users/1')).statusCode, 200);
  });

  test('throwOnViolation wraps error responses too', () async {
    final dio = dioWith((_) => _json({}, status: 404), throwOnViolation: true);
    final error = await dio
        .get<Object?>('/users/1')
        .then<DioException?>(
          (_) => null,
          onError: (Object e) => e as DioException,
        );
    expect(error!.error, isA<ApiValidationException>());
    expect(error.response?.statusCode, 404);
  });

  test('FormData bodies count as a present body', () async {
    final dio = dioWith((_) => ResponseBody.fromString('', 201));
    await dio.post<Object?>(
      '/uploads',
      data: FormData.fromMap({
        'title': 'cat',
        'file': MultipartFile.fromBytes([1, 2, 3], filename: 'cat.png'),
      }),
    );
    final result = checker.results.single;
    expect(result.violations, isEmpty);
    expect(result.exchange.request.body, {'title': 'cat', 'file': 'cat.png'});
  });

  test('byte bodies are passed as Uint8List', () async {
    final dio = dioWith((_) => ResponseBody.fromString('', 201));
    await dio.post<Object?>(
      '/uploads',
      data: <int>[1, 2, 3],
      options: Options(contentType: 'application/octet-stream'),
    );
    final result = checker.results.single;
    expect(result.exchange.request.body, isA<Uint8List>());
    expect(result.exchange.request.contentType, 'application/octet-stream');
    expect(result.violations, isEmpty);
  });

  test('byte responses are decoded by the checker', () async {
    final dio = dioWith((_) => _json({'id': 3, 'name': 'b'}));
    final response = await dio.get<List<int>>(
      '/users/3',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(response.data, isA<List<int>>());
    expect(checker.results.single.exchange.response?.body, isA<Uint8List>());
    expect(checker.results.single.violations, isEmpty);
  });

  test('disabled checker records nothing', () async {
    checker.enabled = false;
    final dio = dioWith((_) => _json({'id': 'bad'}), throwOnViolation: true);
    expect((await dio.get<Object?>('/users/1')).statusCode, 200);
    expect(checker.results, isEmpty);
  });

  test('exchangeFromDio converts headers and request data', () {
    final options = RequestOptions(
      path: 'https://api.example.com/users/1',
      method: 'get',
      headers: {
        'X-Tags': ['a', 'b'],
        'X-Null': null,
      },
      contentType: 'application/json',
      data: {'a': 1},
    );
    final exchange = exchangeFromDio(options);
    expect(exchange.request.method, 'GET');
    expect(exchange.request.header('x-tags'), 'a, b');
    expect(exchange.request.header('x-null'), isNull);
    expect(exchange.request.contentType, 'application/json');
    expect(exchange.request.body, {'a': 1});
    expect(exchange.response, isNull);
  });
}
