import 'dart:convert';

import 'package:api_validator/api_validator.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

void main() {
  final spec = OpenApiSpec.fromString(petStoreYaml);
  late ApiValidator checker;

  setUp(() {
    checker = ApiValidator(spec)
      ..check(
        Exchange(
          request: ExchangeRequest(
            method: 'GET',
            uri: Uri.parse('https://api.example.com/v1/pets/1'),
            headers: {'Authorization': 'Bearer t'},
          ),
          response: ExchangeResponse(
            statusCode: 200,
            body: {'id': 1, 'name': 3},
          ),
        ),
      )
      ..check(
        Exchange(
          request: ExchangeRequest(
            method: 'GET',
            uri: Uri.parse('https://api.example.com/v1/pets/2'),
            headers: {'Authorization': 'Bearer t'},
          ),
          response: ExchangeResponse(statusCode: 404),
        ),
      );
  });

  test('text', () {
    final text = ValidationReporter.text(checker.results);
    expect(text, contains(r'$.name: expected string, got integer'));
    expect(text, contains('2 exchanges checked, 1 error, 0 warnings'));
    expect(
      ValidationReporter.text(checker.results, verbose: true),
      contains('✓ GET /pets/{petId} -> 404'),
    );
  });

  test('json', () {
    final decoded =
        jsonDecode(
              ValidationReporter.json(
                checker.results,
                coverage: checker.coverage,
              ),
            )
            as Map<String, Object?>;
    final results = decoded['results']! as List<Object?>;
    expect(results, hasLength(2));
    expect((results.first! as Map)['conforming'], isFalse);
    expect(decoded['coverage'], isNotNull);
  });

  test('junit escapes and counts failures', () {
    final xml = ValidationReporter.junit(checker.results);
    expect(xml, contains('tests="2" failures="1"'));
    expect(xml, contains('<failure type="schema-mismatch"'));
    expect(xml, contains('-&gt; 200'));
  });

  test('github annotations escape newlines and commas', () {
    final output = ValidationReporter.github(
      checker.results,
      file: 'a,b.json',
      line: 3,
    );
    expect(output, startsWith('::error file=a%2Cb.json,line=3,title='));
    final annotation = ValidationReporter.githubAnnotation(
      checker.errors.single,
      title: 'x',
    );
    expect(annotation, isNot(contains('\n')));
  });

  group('coverage', () {
    test('ratios, untested and text', () {
      final report = checker.coverage;
      expect(report.totalOperations, spec.operations.length);
      expect(report.exercisedOperations, 1);
      expect(report['GET /pets/{petId}']!.missingResponses, isEmpty);
      expect(report.untested.map((e) => e.operationId), contains('listPets'));
      expect(report.toText(), contains('✗ GET /pets  never called'));
      expect(report.operationRatio, closeTo(1 / spec.operations.length, 1e-9));
    });

    test('json round trip and merge', () {
      final report = checker.coverage;
      final restored = CoverageReport.fromJson(
        jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>,
      );
      final merged = restored.merge(report);
      expect(merged['getPet']!.requestCount, 4);
      expect(merged['getPet']!.exercisedResponses, {'200': 2, '404': 2});
      expect(CoverageReport.empty(spec).exercisedOperations, 0);
    });

    test('reset keeps coverage unless asked', () {
      checker.reset();
      expect(checker.coverage.exercisedOperations, 1);
      checker.reset(coverage: true);
      expect(checker.coverage.exercisedOperations, 0);
    });
  });
}
