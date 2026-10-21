import 'dart:math';

import 'package:api_validator/api_validator.dart';
import 'package:api_validator/src/fake/regex_generator.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

OpenApiSpec _inline(String schemas, {String version = '3.1.0'}) =>
    OpenApiSpec.fromString('''
openapi: $version
info: {title: t, version: '1'}
paths: {}
components:
  schemas:
$schemas
''');

int _statusFor(String key) {
  final exact = int.tryParse(key);
  if (exact != null) return exact;
  if (key.toUpperCase().endsWith('XX')) return int.parse(key[0]) * 100 + 99;
  return 599;
}

void main() {
  final petStore = OpenApiSpec.fromString(petStoreYaml);
  final modern = OpenApiSpec.fromString(openApi31Json);

  group('validity across seeds', () {
    for (final (label, spec) in [('3.0', petStore), ('3.1', modern)]) {
      test('every component is valid ($label)', () {
        final validator = SchemaValidator(spec);
        final names =
            (spec.document['components']! as Map<String, Object?>)['schemas']!
                as Map<String, Object?>;
        for (var seed = 0; seed < 50; seed++) {
          final fake = FakeData(spec, seed: seed);
          for (final name in names.keys) {
            final value = fake.component(name);
            expect(
              validator.validate(
                spec.componentSchema(name),
                value,
                direction: SchemaDirection.response,
              ),
              isEmpty,
              reason: '$name (seed $seed): $value',
            );
          }
        }
      });

      test('every response and request body is valid ($label)', () {
        final validator = SchemaValidator(spec);
        for (var seed = 0; seed < 50; seed++) {
          final fake = FakeData(spec, seed: seed);
          for (final operation in spec.operations) {
            for (final key in operation.responses.keys) {
              final status = _statusFor(key);
              final response = operation.responseFor(status)!;
              final body = fake.response(operation.key, status: status);
              final media = response.content.values.firstOrNull;
              if (media?.schema == null) {
                expect(body, isNull);
                continue;
              }
              expect(
                validator.validate(
                  media!.schema,
                  body,
                  direction: SchemaDirection.response,
                ),
                isEmpty,
                reason: '${operation.key} $key (seed $seed): $body',
              );
            }
            final requestBody = operation.requestBody;
            if (requestBody == null) {
              expect(fake.requestBody(operation.key), isNull);
              continue;
            }
            final body = fake.requestBody(operation.key);
            expect(
              validator.validate(
                requestBody.content.values.first.schema,
                body,
                direction: SchemaDirection.request,
              ),
              isEmpty,
              reason: '${operation.key} request (seed $seed): $body',
            );
          }
        }
      });
    }

    test('fake exchanges pass the API validator end to end', () {
      for (var seed = 0; seed < 50; seed++) {
        final fake = FakeData(petStore, seed: seed);
        final checker = ApiValidator(petStore);
        for (final operation in petStore.operations) {
          var path = operation.path;
          for (final parameter in operation.parameters) {
            if (parameter.location == ParameterLocation.path) {
              path = path.replaceAll(
                '{${parameter.name}}',
                '${fake.schema(parameter.schema)}',
              );
            }
          }
          final body = fake.requestBody(operation.key);
          final result = checker.check(
            Exchange(
              request: ExchangeRequest(
                method: operation.method,
                uri: Uri.parse('https://api.example.com/v1$path'),
                headers: {
                  'authorization': 'Bearer t',
                  if (body != null) 'content-type': 'application/json',
                },
                body: body,
              ),
              response: ExchangeResponse(
                statusCode: _statusFor(operation.responses.keys.first),
                headers: fake.responseHeaders(
                  operation.key,
                  status: _statusFor(operation.responses.keys.first),
                ),
                body: fake.response(
                  operation.key,
                  status: _statusFor(operation.responses.keys.first),
                ),
              ),
            ),
          );
          expect(result.errors, isEmpty, reason: '$result (seed $seed)');
        }
      }
    });
  });

  group('determinism', () {
    test('same seed gives identical values', () {
      List<Object?> run(int seed) {
        final fake = FakeData(petStore, seed: seed);
        return [
          fake.component('Pet'),
          fake.response('listPets'),
          fake.requestBody('createPet'),
          fake.component('Shape'),
          fake.responseHeaders('listPets'),
        ];
      }

      for (var seed = 0; seed < 10; seed++) {
        expect(run(seed), equals(run(seed)));
      }
    });

    test('different seeds vary values', () {
      final values = {
        for (var seed = 0; seed < 20; seed++)
          '${FakeData(petStore, seed: seed).component('Pet')}',
      };
      expect(values.length, greaterThan(5));
    });
  });

  group('schemas', () {
    test('readOnly properties are left out of request bodies', () {
      for (var seed = 0; seed < 20; seed++) {
        final body = FakeData(petStore, seed: seed).requestBody('createPet');
        expect((body! as Map<String, Object?>).containsKey('id'), isFalse);
      }
      final pet = FakeData(petStore, seed: 1).response('getPet');
      expect((pet! as Map<String, Object?>)['id'], isA<int>());
    });

    test('writeOnly properties are left out of responses', () {
      final spec = _inline('''
    Account:
      type: object
      required: [password, name]
      properties:
        name: {type: string}
        password: {type: string, writeOnly: true}
''');
      final fake = FakeData(spec, seed: 3);
      final response = fake.component('Account')! as Map<String, Object?>;
      expect(response.containsKey('password'), isFalse);
      final request =
          fake.component('Account', direction: SchemaDirection.request)!
              as Map<String, Object?>;
      expect(request['password'], isA<String>());
    });

    test('discriminator tags are set and every branch appears', () {
      final tags = <Object?>{};
      for (var seed = 0; seed < 30; seed++) {
        final shape =
            FakeData(petStore, seed: seed).component('Shape')!
                as Map<String, Object?>;
        tags.add(shape['kind']);
      }
      expect(tags, {'circle', 'square'});
    });

    test('recursive schemas terminate', () {
      final spec = _inline('''
    Node:
      type: object
      required: [name, next]
      properties:
        name: {type: string}
        next:
          oneOf:
            - {type: 'null'}
            - {\$ref: '#/components/schemas/Node'}
        children:
          type: array
          items: {\$ref: '#/components/schemas/Node'}
        parent: {\$ref: '#/components/schemas/Node'}
''');
      final validator = SchemaValidator(spec);
      for (var seed = 0; seed < 20; seed++) {
        final value = FakeData(spec, seed: seed, maxDepth: 3).component('Node');
        expect(
          validator.validate(spec.componentSchema('Node'), value),
          isEmpty,
        );
      }
    });

    test('recursive nullable required property in 3.0', () {
      final spec = _inline('''
    Link:
      type: object
      required: [next]
      properties:
        next:
          allOf: [{\$ref: '#/components/schemas/Link'}]
          nullable: true
''', version: '3.0.3');
      final value = FakeData(spec, seed: 1).component('Link');
      expect(
        SchemaValidator(spec).isValid(spec.componentSchema('Link'), value),
        isTrue,
      );
    });

    test('valid examples are preferred, invalid ones ignored', () {
      final spec = _inline('''
    Good:
      type: object
      properties: {n: {type: integer}}
      example: {n: 42}
    Bad:
      type: integer
      minimum: 10
      example: 3
    Listed:
      type: string
      examples: [first-choice]
''');
      final fake = FakeData(spec, seed: 1);
      expect(fake.component('Good'), {'n': 42});
      expect(fake.component('Bad'), greaterThanOrEqualTo(10));
      expect(fake.component('Listed'), 'first-choice');
      final noExamples = FakeData(spec, seed: 1, preferExamples: false);
      expect(noExamples.component('Listed'), isNot('first-choice'));
    });

    test('formats are valid', () {
      const formats = [
        'date-time',
        'date',
        'time',
        'email',
        'uuid',
        'uri',
        'uri-reference',
        'ipv4',
        'ipv6',
        'hostname',
        'byte',
      ];
      final spec = _inline(
        [
          for (final format in formats)
            '    F${formats.indexOf(format)}: {type: string, format: $format}',
          '    I32: {type: integer, format: int32}',
          '    I64: {type: integer, format: int64}',
        ].join('\n'),
      );
      final validator = SchemaValidator(spec);
      for (var seed = 0; seed < 30; seed++) {
        final fake = FakeData(spec, seed: seed);
        for (var i = 0; i < formats.length; i++) {
          final value = fake.component('F$i');
          expect(
            validator.isValid(spec.componentSchema('F$i'), value),
            isTrue,
            reason: '${formats[i]}: $value',
          );
        }
        expect(fake.component('I32'), isA<int>());
        expect(fake.component('I64'), isA<int>());
      }
    });

    test('numeric constraints, 3.0 and 3.1 exclusive forms', () {
      final modernSpec = _inline('''
    A: {type: number, exclusiveMinimum: 0, exclusiveMaximum: 1}
    B: {type: number, multipleOf: 0.01, minimum: 1, maximum: 2}
    C: {type: integer, multipleOf: 5, minimum: 7, maximum: 40}
    D: {type: integer, exclusiveMinimum: 9, exclusiveMaximum: 11}
    E: {type: integer, minimum: 1000000}
    F: {type: number, maximum: -50}
''');
      final legacySpec = _inline('''
    A: {type: number, minimum: 0, exclusiveMinimum: true, maximum: 1, exclusiveMaximum: true}
    D: {type: integer, minimum: 9, exclusiveMinimum: true, maximum: 11, exclusiveMaximum: true}
''', version: '3.0.3');
      for (final spec in [modernSpec, legacySpec]) {
        final validator = SchemaValidator(spec);
        final names =
            (spec.document['components']! as Map<String, Object?>)['schemas']!
                as Map<String, Object?>;
        for (var seed = 0; seed < 50; seed++) {
          final fake = FakeData(spec, seed: seed);
          for (final name in names.keys) {
            final value = fake.component(name);
            expect(
              validator.isValid(spec.componentSchema(name), value),
              isTrue,
              reason: '$name: $value',
            );
          }
        }
      }
      expect(FakeData(modernSpec, seed: 1).component('D'), 10);
    });

    test('strings honour length, enum, pattern and names', () {
      final spec = _inline(r'''
    Code: {type: string, pattern: '^[A-Z]{3}-\d{4}$'}
    Alt: {type: string, pattern: '^(foo|bar)baz$'}
    Short: {type: string, maxLength: 3}
    Long: {type: string, minLength: 40}
    Status: {type: string, enum: [on, off]}
    Person:
      type: object
      required: [email, name, city, website, phone]
      properties:
        email: {type: string}
        name: {type: string}
        city: {type: string}
        website: {type: string}
        phone: {type: string}
''');
      final validator = SchemaValidator(spec);
      for (var seed = 0; seed < 30; seed++) {
        final fake = FakeData(spec, seed: seed);
        for (final name in ['Code', 'Alt', 'Short', 'Long', 'Status']) {
          final value = fake.component(name);
          expect(
            validator.isValid(spec.componentSchema(name), value),
            isTrue,
            reason: '$name: $value',
          );
        }
        final person = fake.component('Person')! as Map<String, Object?>;
        expect(person['email'], contains('@'));
        expect(person['name'], contains(' '));
        expect(person['website'], startsWith('https://'));
        expect(person['phone'], startsWith('+'));
      }
    });

    test('unsupported patterns still produce a string', () {
      // Back-references cannot be generated; the value is a best-effort
      // string that is not guaranteed to match.
      final spec = _inline(r'''
    Twice: {type: string, pattern: '^(a+)\1$'}
''');
      expect(FakeData(spec, seed: 1).component('Twice'), isA<String>());
      expect(RegexGenerator(Random(1)).generate(r'^(a+)\1$'), isNull);
    });

    test('arrays honour minItems, maxItems, uniqueItems and prefixItems', () {
      final spec = _inline('''
    Many: {type: array, minItems: 4, maxItems: 6, items: {type: integer}}
    Unique:
      type: array
      minItems: 2
      uniqueItems: true
      items: {type: string, enum: [a, b, c]}
    Tuple:
      type: array
      prefixItems: [{const: x}, {type: integer}]
      items: false
    Contains:
      type: array
      contains: {const: 7}
      items: {type: integer}
''');
      final validator = SchemaValidator(spec);
      for (var seed = 0; seed < 30; seed++) {
        final fake = FakeData(spec, seed: seed);
        for (final name in ['Many', 'Unique', 'Tuple', 'Contains']) {
          final value = fake.component(name);
          expect(
            validator.isValid(spec.componentSchema(name), value),
            isTrue,
            reason: '$name: $value',
          );
        }
      }
    });

    test('objects honour minProperties and additionalProperties', () {
      final spec = _inline('''
    Dictionary:
      type: object
      additionalProperties: {type: integer}
    Padded:
      type: object
      minProperties: 3
      properties: {a: {type: string}}
      additionalProperties: {type: boolean}
    Optional:
      type: object
      properties: {a: {type: string}, b: {type: string}}
''');
      final validator = SchemaValidator(spec);
      final fake = FakeData(spec, seed: 2);
      for (final name in ['Dictionary', 'Padded', 'Optional']) {
        expect(
          validator.isValid(spec.componentSchema(name), fake.component(name)),
          isTrue,
        );
      }
      expect(fake.component('Dictionary'), isNotEmpty);
      expect(
        FakeData(spec, seed: 2, includeOptional: false).component('Optional'),
        isEmpty,
      );
    });

    test('responseHeaders includes declared headers and content type', () {
      final headers = FakeData(petStore, seed: 1).responseHeaders('listPets');
      expect(headers['content-type'], 'application/json');
      expect(int.tryParse(headers['X-Total']!), isNotNull);
    });

    test('unknown references throw ArgumentError', () {
      final fake = FakeData(petStore, seed: 1);
      expect(() => fake.component('Nope'), throwsArgumentError);
      expect(() => fake.response('nope'), throwsArgumentError);
      expect(fake.response('getPet', status: 404), isNull);
    });
  });
}
