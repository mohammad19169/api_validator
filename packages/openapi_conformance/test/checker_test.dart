import 'dart:convert';
import 'dart:typed_data';

import 'package:openapi_conformance/openapi_conformance.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

const _auth = {'authorization': 'Bearer token'};
const _json = {'content-type': 'application/json'};

Exchange _exchange(
  String method,
  String url, {
  Map<String, String> headers = _auth,
  Object? body,
  int? status,
  Map<String, String> responseHeaders = _json,
  Object? responseBody,
}) => Exchange(
  request: ExchangeRequest(
    method: method,
    uri: Uri.parse('https://api.example.com/v1$url'),
    headers: headers,
    body: body,
  ),
  response: status == null
      ? null
      : ExchangeResponse(
          statusCode: status,
          headers: responseHeaders,
          body: responseBody,
        ),
);

void main() {
  final spec = OpenApiSpec.fromString(petStoreYaml);
  late ConformanceChecker checker;

  setUp(() => checker = ConformanceChecker(spec));

  List<String> kinds(ConformanceResult result) => [
    for (final violation in result.violations) violation.kind,
  ];

  group('routing', () {
    test('conforming exchange has no violations', () {
      final result = checker.check(
        _exchange(
          'GET',
          '/pets/7',
          status: 200,
          responseBody: '{"id": 7, "name": "Rex"}',
        ),
      );
      expect(result.violations, isEmpty);
      expect(result.operation?.operationId, 'getPet');
      expect(result.responseKey, '200');
      expect(result.label, 'GET /pets/{petId} -> 200');
    });

    test('literal paths beat templates', () {
      final result = checker.check(
        _exchange('GET', '/pets/mine', status: 200, responseBody: '[]'),
      );
      expect(result.operation?.operationId, 'myPets');
    });

    test('unknown path is an error by default', () {
      final result = checker.check(_exchange('GET', '/nope'));
      expect(kinds(result), ['unknown-operation']);
      expect(result.isConforming, isFalse);
    });

    test('unknown path policy can be relaxed', () {
      final warn = ConformanceChecker(
        spec,
        options: const ConformanceOptions(
          unmatchedRequests: UnmatchedPolicy.warning,
        ),
      );
      expect(warn.check(_exchange('GET', '/nope')).isConforming, isTrue);
      final ignore = ConformanceChecker(
        spec,
        options: const ConformanceOptions(
          unmatchedRequests: UnmatchedPolicy.ignore,
        ),
      );
      expect(ignore.check(_exchange('GET', '/nope')).skipped, isTrue);
      expect(ignore.results, isEmpty);
    });

    test('wrong method is reported with allowed methods', () {
      final result = checker.check(_exchange('PUT', '/pets/1'));
      final violation = result.violations.single as MethodNotAllowed;
      expect(violation.allowedMethods, containsAll(['GET', 'DELETE']));
    });

    test('ignored operations and paths are skipped', () {
      final custom = ConformanceChecker(
        spec,
        options: ConformanceOptions(
          ignoreOperations: const ['getPet'],
          ignorePaths: [RegExp(r'^/v1/health')],
        ),
      );
      expect(custom.check(_exchange('GET', '/pets/abc')).skipped, isTrue);
      expect(custom.check(_exchange('GET', '/health')).skipped, isTrue);
    });
  });

  group('request', () {
    test('invalid path parameter', () {
      final result = checker.check(_exchange('GET', '/pets/abc'));
      final violation = result.violations.single as InvalidParameter;
      expect(violation.location, ViolationLocation.requestPath);
      expect(violation.message, contains('expected integer'));
    });

    test('query parameters are coerced and validated', () {
      expect(
        checker
            .check(_exchange('GET', '/pets?limit=10&tags=a&tags=b'))
            .violations,
        isEmpty,
      );
      final result = checker.check(_exchange('GET', '/pets?limit=500'));
      expect(result.violations.single.message, contains('<= 100'));
    });

    test('missing credentials is a warning', () {
      final result = checker.check(_exchange('GET', '/pets', headers: {}));
      expect(kinds(result), ['missing-credentials']);
      expect(result.isConforming, isTrue);
    });

    test('anonymous security requirement needs no credentials', () {
      final result = checker.check(_exchange('GET', '/pets/mine', headers: {}));
      expect(result.violations, isEmpty);
    });

    test('missing required body', () {
      final result = checker.check(_exchange('POST', '/pets'));
      expect(kinds(result), ['missing-body']);
    });

    test('request body schema errors carry JSON paths', () {
      final result = checker.check(
        _exchange(
          'POST',
          '/pets',
          headers: {..._auth, ..._json},
          body: {'name': '', 'status': 'lost', 'birthday': '2024-02-30'},
        ),
      );
      expect([
        for (final v in result.violations) v.jsonPath,
      ], containsAll([r'$.name', r'$.status', r'$.birthday']));
    });

    test('readOnly property in a request is reported', () {
      final result = checker.check(
        _exchange(
          'POST',
          '/pets',
          headers: {..._auth, ..._json},
          body: '{"id": 1, "name": "Rex"}',
        ),
      );
      expect(result.violations.single.message, contains('read-only'));
    });

    test('undeclared request content type', () {
      final result = checker.check(
        _exchange(
          'POST',
          '/pets',
          headers: {..._auth, 'content-type': 'text/xml'},
          body: '<pet/>',
        ),
      );
      expect(kinds(result), ['unsupported-content-type']);
    });

    test('discriminator selects the mapped schema', () {
      ConformanceResult shape(Object body) => checker.check(
        _exchange('POST', '/shapes', headers: _json, body: body),
      );
      expect(shape({'kind': 'circle', 'radius': 2}).violations, isEmpty);
      expect(shape({'kind': 'square', 'side': 2}).violations, isEmpty);
      expect(
        shape({'kind': 'circle', 'radius': 0}).violations.single.message,
        contains('> 0'),
      );
      expect(
        shape({'kind': 'hexagon'}).violations.single.message,
        contains('unknown discriminator value'),
      );
    });
  });

  group('response', () {
    test('type mismatch in nested response', () {
      final result = checker.check(
        _exchange(
          'GET',
          '/pets/1',
          status: 200,
          responseBody: {
            'id': 1,
            'name': 'Rex',
            'owner': {'email': 'not-an-email'},
          },
        ),
      );
      expect(result.violations.single.jsonPath, r'$.owner.email');
    });

    test('nullable fields accept null', () {
      final result = checker.check(
        _exchange(
          'GET',
          '/pets/1',
          status: 200,
          responseBody: {'id': 1, 'name': 'Rex', 'tag': null, 'owner': null},
        ),
      );
      expect(result.violations, isEmpty);
    });

    test('null in non-nullable field hints at nullable', () {
      final result = checker.check(
        _exchange(
          'GET',
          '/pets/1',
          status: 200,
          responseBody: {'id': 1, 'name': null},
        ),
      );
      expect(result.violations.single.message, contains('nullable'));
    });

    test('undeclared status is an error in strict mode', () {
      final result = checker.check(_exchange('GET', '/pets/1', status: 500));
      final violation = result.violations.single as UndeclaredStatus;
      expect(violation.declaredStatuses, ['200', '404']);
      expect(violation.isError, isTrue);
    });

    test('status ranges and default match', () {
      final error = '{"code": 1, "message": "bad"}';
      final range = checker.check(
        _exchange(
          'POST',
          '/pets',
          headers: {..._auth, ..._json},
          body: '{"name": "a"}',
          status: 422,
          responseBody: error,
        ),
      );
      expect(range.responseKey, '4XX');
      expect(range.violations, isEmpty);
      final fallback = checker.check(
        _exchange(
          'GET',
          '/pets',
          status: 503,
          responseBody: error,
          responseHeaders: _json,
        ),
      );
      expect(fallback.responseKey, 'default');
      expect(fallback.violations, isEmpty);
    });

    test('required response header', () {
      final missing = checker.check(
        _exchange('GET', '/pets', status: 200, responseBody: '[]'),
      );
      expect(missing.violations.single, isA<MissingParameter>());
      final present = checker.check(
        _exchange(
          'GET',
          '/pets',
          status: 200,
          responseHeaders: {..._json, 'x-total': '3'},
          responseBody: '[]',
        ),
      );
      expect(present.violations, isEmpty);
    });

    test('undeclared property severity depends on mode', () {
      final exchange = _exchange(
        'GET',
        '/pets/1',
        status: 200,
        responseBody: {'id': 1, 'name': 'Rex', 'colour': 'brown'},
      );
      final strict = checker.check(exchange);
      expect(strict.violations.single, isA<UndeclaredProperty>());
      expect(strict.isConforming, isFalse);
      final lenient = ConformanceChecker(
        spec,
        options: const ConformanceOptions(mode: ConformanceMode.lenient),
      ).check(exchange);
      expect(lenient.violations.single.severity, Severity.warning);
      expect(lenient.isConforming, isTrue);
    });

    test('invalid JSON and byte bodies', () {
      final invalid = checker.check(
        _exchange('GET', '/pets/1', status: 200, responseBody: '{oops'),
      );
      expect(invalid.violations.single, isA<InvalidJson>());
      final bytes = checker.check(
        _exchange(
          'GET',
          '/pets/1',
          status: 200,
          responseHeaders: const {},
          responseBody: Uint8List.fromList(
            utf8.encode('{"id": 1, "name": "Rex"}'),
          ),
        ),
      );
      expect(bytes.violations, isEmpty);
    });

    test('empty body where content is declared', () {
      final result = checker.check(_exchange('GET', '/pets/1', status: 200));
      expect(result.violations.single.message, contains('empty'));
    });

    test('deprecated operation is a warning', () {
      final result = checker.check(_exchange('DELETE', '/pets/1', status: 204));
      expect(kinds(result), ['deprecated-operation']);
      expect(result.isConforming, isTrue);
    });
  });

  group('recording', () {
    test('results, coverage, stream and verify', () async {
      final seen = <ConformanceResult>[];
      final subscription = checker.onResult.listen(seen.add);
      checker
        ..check(
          _exchange(
            'GET',
            '/pets/1',
            status: 200,
            responseBody: {'id': 1, 'name': 'a'},
          ),
        )
        ..check(_exchange('GET', '/pets/x', status: 404));
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(2));
      expect(checker.errors, hasLength(1));
      expect(checker.isConforming, isFalse);
      expect(checker.verify, throwsA(isA<ConformanceException>()));
      expect(checker.results, isEmpty);
      final coverage = checker.coverage['getPet']!;
      expect(coverage.exercisedResponses, {'200': 1, '404': 1});
      expect(coverage.missingResponses, isEmpty);
      await subscription.cancel();
      await checker.dispose();
    });

    test('disabled checker records nothing', () {
      checker.enabled = false;
      final result = checker.check(_exchange('GET', '/nope'));
      expect(result.skipped, isTrue);
      expect(checker.results, isEmpty);
    });

    test('onViolation and maxRecordedResults', () {
      final found = <Violation>[];
      final bounded = ConformanceChecker(
        spec,
        options: ConformanceOptions(
          maxRecordedResults: 2,
          onViolation: found.add,
        ),
      );
      for (var i = 0; i < 5; i++) {
        bounded.check(_exchange('GET', '/nope/$i'));
      }
      expect(bounded.results, hasLength(2));
      expect(found, hasLength(5));
    });
  });

  group('OpenAPI 3.1', () {
    final modern = ConformanceChecker(OpenApiSpec.fromString(openApi31Json));

    Exchange item(String id, Object body) => Exchange(
      request: ExchangeRequest(
        method: 'GET',
        uri: Uri.parse('https://x.dev/items/$id.json'),
      ),
      response: ExchangeResponse(statusCode: 200, body: body),
    );

    test('partial segment templates, type arrays and prefixItems', () {
      expect(
        modern
            .check(
              item('abc', {
                'id': 'abc',
                'note': null,
                'tags': ['first', 'x'],
                'child': {
                  'id': 'c',
                  'tags': ['first'],
                },
              }),
            )
            .violations,
        isEmpty,
      );
      final result = modern.check(
        item('ABC', {
          'id': 'abc',
          'score': 0,
          'tags': ['second'],
        }),
      );
      expect(
        [for (final v in result.violations) v.location],
        containsAll([
          ViolationLocation.requestPath,
          ViolationLocation.responseBody,
        ]),
      );
      expect(result.violations, hasLength(3));
    });
  });
}
