import 'dart:convert';
import 'dart:io';

import 'package:matcher/matcher.dart' as m;
import 'package:openapi_conformance_test/openapi_conformance_test.dart';
import 'package:test/test.dart';

const _spec = r'''
openapi: 3.0.3
info: {title: Test, version: '1'}
paths:
  /pets/{id}:
    get:
      operationId: getPet
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema: {$ref: '#/components/schemas/Pet'}
        4XX:
          description: client error
  /pets:
    post:
      operationId: createPet
      requestBody:
        content:
          application/json:
            schema: {$ref: '#/components/schemas/Pet'}
      responses:
        '201': {description: created}
components:
  schemas:
    Pet:
      type: object
      required: [id, name]
      properties:
        id: {type: integer, readOnly: true}
        name: {type: string}
''';

Exchange _get(String path, {int status = 200, Object? body}) => Exchange(
  request: ExchangeRequest(method: 'GET', uri: Uri.parse(path)),
  response: ExchangeResponse(statusCode: status, body: body),
);

String _mismatch(Object? item, Matcher matcher) {
  final state = <Object?, Object?>{};
  expect(matcher.matches(item, state), isFalse);
  return matcher
      .describeMismatch(item, m.StringDescription(), state, false)
      .toString();
}

void main() {
  final spec = OpenApiSpec.fromString(_spec);
  late ConformanceChecker checker;

  setUp(() => checker = ConformanceChecker(spec));

  group('isConforming / hasNoViolations', () {
    test('accept checkers, results and violation lists', () {
      final result = checker.check(
        _get('/pets/1', body: {'id': 1, 'name': 'a'}),
      );
      expect(checker, isConforming);
      expect(result, hasNoViolations);
      expect(<Violation>[], isConforming);
    });

    test('warnings pass isConforming but fail hasNoViolations', () {
      final lenient = ConformanceChecker(
        spec,
        options: const ConformanceOptions(mode: ConformanceMode.lenient),
      );
      lenient.check(_get('/pets/1', body: {'id': 1, 'name': 'a', 'x': 1}));
      expect(lenient, isConforming);
      expect(_mismatch(lenient, hasNoViolations), contains('warning'));
    });

    test('mismatch lists every violation', () {
      checker.check(_get('/pets/1', body: {'id': 'x'}));
      final text = _mismatch(checker, isConforming);
      expect(text, contains('has 2 violations'));
      expect(text, contains(r'$.id'));
      expect(text, contains(r'$.name'));
      expect(() => expect(checker, isConforming), throwsA(isA<TestFailure>()));
    });

    test('reject unsupported values', () {
      expect(_mismatch(42, isConforming), contains('is not a'));
    });
  });

  group('hasViolation', () {
    setUp(() => checker.check(_get('/pets/x', status: 500)));

    test('matches by type, kind, location and severity', () {
      expect(checker, hasViolation(type: InvalidParameter));
      expect(checker, hasViolation(kind: 'undeclared-status'));
      expect(
        checker,
        hasViolation(
          location: ViolationLocation.requestPath,
          severity: Severity.error,
          message: 'expected integer',
        ),
      );
      expect(checker, hasViolation(message: m.startsWith('status 500')));
    });

    test('matches by JSON path', () {
      final result = checker.check(_get('/pets/1', body: {'id': 1}));
      expect(result, hasViolation(jsonPath: r'$.name'));
    });

    test('describes what it found instead', () {
      final text = _mismatch(checker, hasViolation(type: SchemaMismatch));
      expect(text, contains('InvalidParameter'));
      expect(_mismatch(<Violation>[], hasViolation()), 'has no violations');
      expect(
        hasViolation(
          kind: 'x',
          message: 'y',
        ).describe(m.StringDescription()).toString(),
        contains('kind "x"'),
      );
    });
  });

  group('exercised', () {
    test('checks operations and statuses', () {
      checker
        ..check(_get('/pets/1', body: {'id': 1, 'name': 'a'}))
        ..check(_get('/pets/1', status: 404));
      expect(checker, exercised('getPet'));
      expect(checker, exercised('get /pets/{id}', status: 200));
      expect(checker, exercised('getPet', status: 404));
      expect(checker.coverage, exercised('getPet', status: '4xx'));
      expect(_mismatch(checker, exercised('createPet')), 'was never called');
      expect(
        _mismatch(checker, exercised('getPet', status: 500)),
        contains('only returned'),
      );
      expect(
        _mismatch(checker, exercised('nope')),
        contains('has no operation'),
      );
      expect(() => exercised('getPet', status: 1.5), throwsArgumentError);
    });
  });

  group('conformsTo', () {
    test('responses accept maps and JSON strings', () {
      expect({'id': 1, 'name': 'a'}, conformsToResponse(spec, 'getPet'));
      expect('{"id": 1, "name": "a"}', conformsToResponse(spec, 'getPet'));
      final text = _mismatch({'id': 'x'}, conformsToResponse(spec, 'getPet'));
      expect(text, contains(r'$.id'));
      expect(text, contains(r'$.name'));
      expect(
        _mismatch('{bad', conformsToResponse(spec, 'getPet')),
        contains('not valid JSON'),
      );
    });

    test('lenient mode tolerates undeclared properties', () {
      final value = {'id': 1, 'name': 'a', 'extra': true};
      expect(value, m.isNot(conformsToResponse(spec, 'getPet')));
      expect(
        value,
        conformsToResponse(spec, 'getPet', mode: ConformanceMode.lenient),
      );
    });

    test('request bodies honour readOnly', () {
      expect({'name': 'a'}, conformsToRequestBody(spec, 'createPet'));
      expect({
        'id': 1,
        'name': 'a',
      }, m.isNot(conformsToRequestBody(spec, 'createPet')));
    });

    test('component schemas', () {
      expect({'id': 1, 'name': 'a'}, conformsToSchema(spec, 'Pet'));
      expect({'id': 1}, m.isNot(conformsToSchema(spec, 'Pet')));
    });

    test('invalid arguments throw early', () {
      expect(() => conformsToResponse(spec, 'nope'), throwsArgumentError);
      expect(
        () => conformsToResponse(spec, 'getPet', status: 500),
        throwsArgumentError,
      );
      expect(() => conformsToRequestBody(spec, 'getPet'), throwsArgumentError);
      expect(() => conformsToSchema(spec, 'Nope'), throwsArgumentError);
    });
  });

  group('describeConformanceFailures', () {
    test('returns null when nothing fails', () {
      checker.check(_get('/pets/1', body: {'id': 1, 'name': 'a'}));
      expect(describeConformanceFailures(checker), isNull);
    });

    test('respects failOnErrors and failOnWarnings', () {
      final lenient = ConformanceChecker(
        spec,
        options: const ConformanceOptions(mode: ConformanceMode.lenient),
      )..check(_get('/pets/1', body: {'id': 1, 'name': 'a', 'x': 1}));
      expect(describeConformanceFailures(lenient), isNull);
      expect(
        describeConformanceFailures(lenient, failOnWarnings: true),
        contains('1 violation'),
      );
      checker.check(_get('/nope'));
      expect(
        describeConformanceFailures(checker),
        allOf(contains('does not match'), contains('/nope')),
      );
      expect(describeConformanceFailures(checker, failOnErrors: false), isNull);
    });
  });

  group('useConformance', () {
    final directory = Directory.systemTemp.createTempSync('oc_test_');
    final suiteChecker = useConformance(
      ConformanceChecker(spec),
      coverageDirectory: directory.path,
    );

    test('records traffic of a conforming test', () {
      suiteChecker.check(_get('/pets/1', body: {'id': 1, 'name': 'a'}));
      expect(suiteChecker.results, hasLength(1));
    });

    test('results are reset between tests, coverage is kept', () {
      expect(suiteChecker.results, isEmpty);
      expect(suiteChecker, exercised('getPet', status: 200));
    });
  });

  test('useConformance wrote a coverage file', () async {
    final directories = Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('oc_test_'));
    final files = [
      for (final d in directories)
        if (d.existsSync())
          ...d.listSync().whereType<File>().where(
            (f) => f.path.endsWith('.json'),
          ),
    ];
    expect(files, isNotEmpty);
    final report = CoverageReport.fromJson(
      jsonDecode(files.last.readAsStringSync()) as Map<String, Object?>,
    );
    expect(report, exercised('getPet'));
    for (final d in directories) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('writeCoverageReport', () async {
    final directory = await Directory.systemTemp.createTemp('oc_write_');
    addTearDown(() => directory.delete(recursive: true));
    final path = await writeCoverageReport(
      CoverageReport.empty(spec),
      directory.path,
    );
    expect(File(path!).existsSync(), isTrue);
  });

  group('useConformanceFromFile', () {
    final directory = Directory.systemTemp.createTempSync('oc_spec_');
    final specFile = File('${directory.path}/spec.yaml')
      ..writeAsStringSync(_spec);
    final fileChecker = useConformanceFromFile(
      specFile.path,
      coverageDirectory: null,
    );

    test('loads the spec from disk', () {
      expect(fileChecker.spec.operation('getPet'), isNotNull);
      directory.deleteSync(recursive: true);
    });
  });
}
