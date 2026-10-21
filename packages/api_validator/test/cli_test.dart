@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:api_validator/src/cli/cli.dart';
import 'package:api_validator/src/coverage/coverage.dart';
import 'package:api_validator/src/spec/openapi_spec.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/specs.dart';

final class _Run {
  _Run(this.code, this.out, this.err);

  final int code;
  final String out;
  final String err;
}

void main() {
  late Directory dir;

  String file(String name, String contents) {
    final f = File(p.join(dir.path, name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
    return f.path;
  }

  Future<_Run> run(List<String> args) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(args, out: out, err: err);
    return _Run(code, '$out', '$err');
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('api_validator_cli');
    file('openapi.yaml', petStoreYaml);
    file('fixtures/pet.json', '{"id": 1, "name": "Rex"}');
    file('fixtures/bad_pet.json', '{"id": "one", "name": "Rex"}');
    file('fixtures/extra.json', '{"id": 1, "name": "Rex", "colour": "red"}');
    file('fixtures/new_pet.json', '{"name": "Rex"}');
    file('fixtures/broken.json', '{oops');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String spec() => p.join(dir.path, 'openapi.yaml');
  String fixture(String name) => p.join(dir.path, 'fixtures', name);

  group('check', () {
    test('passing fixtures exit with 0', () async {
      final result = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('pet.json')}=getPet:200',
        '--fixture',
        '${fixture('new_pet.json')}=POST /pets:request',
      ]);
      expect(result.code, 0, reason: result.err);
      expect(result.out, contains('✓'));
      expect(result.out, contains('2 items checked, 0 errors, 0 warnings'));
    });

    test('schema errors exit with 1 and show JSON paths', () async {
      final result = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('bad_pet.json')}=getPet:200',
        '--fixture',
        '${fixture('broken.json')}=getPet:200',
      ]);
      expect(result.code, 1);
      expect(result.out, contains(r'$.id: expected integer, got string'));
      expect(result.out, contains('not valid JSON'));
    });

    test('lenient mode turns undeclared properties into warnings', () async {
      final args = [
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('extra.json')}=getPet:200',
      ];
      expect((await run(args)).code, 1);
      final lenient = await run([...args, '--mode', 'lenient']);
      expect(lenient.code, 0);
      expect(lenient.out, contains('1 warning'));
      expect(
        (await run([...args, '--mode', 'lenient', '--fail-on-warnings'])).code,
        1,
      );
    });

    test('undeclared status is reported', () async {
      final result = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('pet.json')}=getPet:500',
      ]);
      expect(result.code, 1);
      expect(result.out, contains('status 500 is not declared'));
    });

    test('config file with globs and HAR', () async {
      file(
        'recordings/session.har',
        jsonEncode({
          'log': {
            'entries': [
              {
                'request': {
                  'method': 'GET',
                  'url': 'https://api.example.com/v1/pets/1',
                  'headers': [
                    {'name': 'Authorization', 'value': 'Bearer t'},
                  ],
                },
                'response': {
                  'status': 200,
                  'headers': <Object?>[],
                  'content': {
                    'mimeType': 'application/json',
                    'text': '{"id": 1, "name": 5}',
                  },
                },
              },
              {
                'request': {
                  'method': 'GET',
                  'url': 'https://cdn.example.com/logo.png',
                  'headers': <Object?>[],
                },
                'response': {'status': 200, 'headers': <Object?>[]},
              },
            ],
          },
        }),
      );
      final config = file('api_validator.yaml', '''
spec: openapi.yaml
mode: strict
fixtures:
  - glob: fixtures/p*.json
    operation: getPet
    status: 200
  - path: fixtures/new_pet.json
    operation: createPet
    direction: request
har:
  - recordings/session.har
''');
      final result = await run(['check', '--config', config]);
      expect(result.code, 1);
      expect(result.out, contains('pet.json'));
      expect(result.out, contains('session.har#1'));
      expect(result.out, contains(r'$.name: expected string'));
      expect(result.out, contains('no operation in the spec matches'));
      expect(result.out, contains('4 items checked, 1 error, 1 warning'));
    });

    test('json, junit and github reporters', () async {
      final args = [
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('bad_pet.json')}=getPet:200',
      ];
      final json = await run([...args, '--reporter', 'json']);
      final decoded = jsonDecode(json.out) as Map<String, Object?>;
      expect((decoded['summary']! as Map<String, Object?>)['errors'], 1);

      final junit = await run([...args, '--reporter', 'junit']);
      expect(junit.out, contains('<testsuite name="api_validator"'));
      expect(junit.out, contains('<failure type="schema-mismatch"'));

      final github = await run([...args, '--reporter', 'github']);
      expect(github.out, contains('::error file='));
      expect(github.out, contains('bad_pet.json,line=1,'));
      expect(github.out, isNot(contains(r'\')));
    });

    test('--output writes the report to a file', () async {
      final output = p.join(dir.path, 'out', 'report.xml');
      final result = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('pet.json')}=getPet:200',
        '--reporter',
        'junit',
        '--output',
        output,
      ]);
      expect(result.code, 0);
      expect(File(output).readAsStringSync(), contains('<testcase'));
      expect(result.out, contains('Report written to'));
    });

    test('usage and configuration errors exit with 2', () async {
      expect((await run(['check'])).code, 2);
      expect((await run(['check', '--spec', spec()])).code, 2);
      final unknown = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        '${fixture('pet.json')}=nope:200',
      ]);
      expect(unknown.code, 2);
      expect(unknown.err, contains('no operation matches "nope"'));
      final badFixture = await run([
        'check',
        '--spec',
        spec(),
        '--fixture',
        'pet.json',
      ]);
      expect(badFixture.code, 2);
      expect(
        (await run(['check', '--spec', p.join(dir.path, 'missing.yaml')])).err,
        contains('not found'),
      );
      expect((await run(['bogus'])).code, 2);
    });

    test('help is written to out', () async {
      final result = await run(['--help']);
      expect(result.code, 0);
      expect(result.out, contains('check'));
      expect(result.out, contains('diff'));
      expect(result.out, contains('coverage'));
    });
  });

  group('diff', () {
    late String newSpec;

    setUp(() {
      newSpec = file(
        'openapi_v2.yaml',
        petStoreYaml.replaceFirst(
          'required: [name]\n      properties:\n        id: { type: integer, readOnly: true }\n        name: { type: string, minLength: 1 }',
          'required: [name]\n      properties:\n        id: { type: integer, readOnly: true }\n        name: { type: integer }',
        ),
      );
    });

    test('breaking changes exit with 1', () async {
      final result = await run(['diff', spec(), newSpec]);
      expect(result.code, 1, reason: result.err);
      expect(result.out, contains('Breaking:'));
      expect(result.out, contains(r'$.name'));
    });

    test('identical specs exit with 0', () async {
      final result = await run(['diff', spec(), spec()]);
      expect(result.code, 0);
      expect(result.out, contains('No changes'));
    });

    test('--fail-on none always exits with 0', () async {
      final result = await run(['diff', spec(), newSpec, '--fail-on', 'none']);
      expect(result.code, 0);
    });

    test('--fail-on potentially-breaking', () async {
      final extra = file(
        'openapi_v3.yaml',
        petStoreYaml.replaceFirst(
          'enum: [available, sold]',
          'enum: [available, sold, reserved]',
        ),
      );
      expect((await run(['diff', spec(), extra])).code, 0);
      expect(
        (await run([
          'diff',
          spec(),
          extra,
          '--fail-on',
          'potentially-breaking',
        ])).code,
        1,
      );
    });

    test('re-checks fixtures from the config against the new spec', () async {
      final config = file('api_validator.yaml', '''
spec: openapi.yaml
fixtures:
  - path: fixtures/pet.json
    operation: getPet
    status: 200
''');
      final result = await run(['diff', spec(), newSpec, '--config', config]);
      expect(result.out, contains('1 of 1 fixtures break with the new spec'));
      final json = await run([
        'diff',
        spec(),
        newSpec,
        '--config',
        config,
        '--reporter',
        'json',
      ]);
      final decoded = jsonDecode(json.out) as Map<String, Object?>;
      expect(
        (decoded['fixtures']! as Map<String, Object?>)['broken'],
        hasLength(1),
      );
    });

    test('github reporter emits annotations', () async {
      final result = await run([
        'diff',
        spec(),
        newSpec,
        '--reporter',
        'github',
      ]);
      expect(result.out, contains('::error title=Breaking API change::'));
    });

    test('needs exactly two specs', () async {
      expect((await run(['diff', spec()])).code, 2);
    });
  });

  group('coverage', () {
    late String coverageDir;

    setUp(() {
      final spec = OpenApiSpec.fromString(petStoreYaml);
      final tracker = CoverageTracker(spec)
        ..record(spec.requireOperation('getPet'), responseKey: '200');
      final other = CoverageTracker(spec)
        ..record(spec.requireOperation('listPets'), responseKey: '200')
        ..record(spec.requireOperation('getPet'), responseKey: '404');
      coverageDir = p.join(dir.path, 'coverage');
      file('coverage/a.json', jsonEncode(tracker.report.toJson()));
      file('coverage/nested/b.json', jsonEncode(other.report.toJson()));
    });

    test('merges files and prints a summary', () async {
      final output = p.join(dir.path, 'merged.json');
      final result = await run(['coverage', coverageDir, '-o', output]);
      expect(result.code, 0, reason: result.err);
      expect(result.out, contains('API coverage: 2/6 operations'));
      final merged = CoverageReport.fromJson(
        jsonDecode(File(output).readAsStringSync()) as Map<String, Object?>,
      );
      expect(merged['getPet']!.exercisedResponses, {'200': 1, '404': 1});
    });

    test('thresholds fail the run', () async {
      final result = await run([
        'coverage',
        coverageDir,
        '--min-operations',
        '50',
      ]);
      expect(result.code, 1);
      expect(result.out, contains('is below 50.0%'));
      expect(
        (await run(['coverage', coverageDir, '--min-operations', '20'])).code,
        0,
      );
    });

    test('json and github reporters', () async {
      final json = await run(['coverage', coverageDir, '-r', 'json']);
      expect(
        (jsonDecode(json.out) as Map<String, Object?>)['summary'],
        isNotNull,
      );
      final github = await run([
        'coverage',
        coverageDir,
        '-r',
        'github',
        '--min-responses',
        '90',
      ]);
      expect(github.code, 1);
      expect(github.out, contains('::warning title=Untested API operation::'));
      expect(github.out, contains('::error title=API coverage::'));
    });

    test('missing input and bad thresholds exit with 2', () async {
      expect((await run(['coverage', p.join(dir.path, 'none')])).code, 2);
      expect(
        (await run(['coverage', coverageDir, '--min-operations', 'x'])).code,
        2,
      );
      file('bad/c.json', '{"nope": true}');
      expect((await run(['coverage', p.join(dir.path, 'bad')])).code, 2);
    });
  });

  group('fake', () {
    test('prints a schema-valid response, reproducibly', () async {
      final first = await run([
        'fake',
        '--spec',
        spec(),
        '--seed',
        '7',
        'getPet',
      ]);
      final second = await run([
        'fake',
        '--spec',
        spec(),
        '--seed',
        '7',
        'getPet',
      ]);
      expect(first.code, 0, reason: first.err);
      expect(first.out, second.out);
      final value = jsonDecode(first.out) as Map<String, Object?>;
      expect(value, containsPair('name', isA<String>()));
    });

    test('request bodies, components and edge cases', () async {
      final request = await run([
        'fake',
        '-s',
        spec(),
        '--request',
        'createPet',
      ]);
      expect(jsonDecode(request.out), isNot(contains('id')));
      final component = await run([
        'fake',
        '-s',
        spec(),
        '--component',
        'Error',
      ]);
      expect(jsonDecode(component.out), contains('code'));
      final edges = await run(['fake', '-s', spec(), '--edge-cases', 'getPet']);
      final list = jsonDecode(edges.out) as List<Object?>;
      expect(list, isNotEmpty);
      expect((list.first! as Map)['description'], isA<String>());
    });

    test('unknown operation and missing arguments are usage errors', () async {
      expect((await run(['fake', '-s', spec(), 'nope'])).code, 2);
      expect((await run(['fake', '-s', spec()])).code, 2);
    });
  });
}
