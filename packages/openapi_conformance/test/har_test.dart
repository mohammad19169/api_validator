import 'dart:convert';
import 'dart:typed_data';

import 'package:openapi_conformance/src/core/checker.dart';
import 'package:openapi_conformance/src/har/har.dart';
import 'package:openapi_conformance/src/spec/openapi_spec.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

String harOf(List<Map<String, Object?>> entries) => jsonEncode({
  'log': {
    'version': '1.2',
    'creator': {'name': 'test', 'version': '1'},
    'entries': entries,
  },
});

Map<String, Object?> entry({
  String method = 'GET',
  String url = 'https://api.example.com/v1/pets/1',
  int status = 200,
  Map<String, Object?>? postData,
  Map<String, Object?>? content,
  List<Map<String, Object?>> requestHeaders = const [
    {'name': 'Authorization', 'value': 'Bearer x'},
  ],
}) => {
  'request': {
    'method': method,
    'url': url,
    'headers': requestHeaders,
    'postData': ?postData,
  },
  'response': {
    'status': status,
    'headers': [
      {'name': ':status', 'value': '$status'},
    ],
    'content': ?content,
  },
};

void main() {
  test('parses requests, responses and headers', () {
    final exchanges = parseHar(
      harOf([
        entry(
          method: 'POST',
          url: 'https://api.example.com/v1/pets',
          status: 201,
          postData: {'mimeType': 'application/json', 'text': '{"name":"a"}'},
          content: {
            'mimeType': 'application/json',
            'text': '{"id":1,"name":"a"}',
          },
        ),
      ]),
    );
    final exchange = exchanges.single;
    expect(exchange.request.method, 'POST');
    expect(exchange.request.uri.path, '/v1/pets');
    expect(exchange.request.header('authorization'), 'Bearer x');
    expect(exchange.request.contentType, 'application/json');
    expect(exchange.request.body, '{"name":"a"}');
    expect(exchange.response!.statusCode, 201);
    expect(exchange.response!.contentType, 'application/json');
    expect(exchange.response!.headers.containsKey(':status'), isFalse);
  });

  test('decodes base64 bodies and form params, skips status 0', () {
    final exchanges = parseHar(
      harOf([
        entry(status: 0),
        entry(
          content: {
            'mimeType': 'application/json',
            'encoding': 'base64',
            'text': base64Encode(utf8.encode('{"id":1,"name":"Rex"}')),
          },
        ),
        entry(
          method: 'POST',
          postData: {
            'mimeType': 'application/x-www-form-urlencoded',
            'params': [
              {'name': 'a b', 'value': '1&2'},
              {'name': 'c', 'value': '3'},
            ],
          },
        ),
      ]),
    );
    expect(exchanges, hasLength(2));
    expect(exchanges.first.response!.body, isA<Uint8List>());
    expect(exchanges.last.request.body, 'a+b=1%262&c=3');
  });

  test('parsed exchanges can be checked', () {
    final checker = ConformanceChecker(OpenApiSpec.fromString(petStoreYaml));
    final exchanges = parseHar(
      harOf([
        entry(
          content: {
            'mimeType': 'application/json',
            'text': '{"id":1,"name":"Rex"}',
          },
        ),
        entry(content: {'mimeType': 'application/json', 'text': '{"id":"x"}'}),
      ]),
    );
    expect(checker.check(exchanges.first).violations, isEmpty);
    expect(checker.check(exchanges.last).isConforming, isFalse);
  });

  test('rejects documents that are not HAR', () {
    expect(() => parseHar('nope'), throwsFormatException);
    expect(() => parseHar('{"log": {}}'), throwsFormatException);
  });
}
