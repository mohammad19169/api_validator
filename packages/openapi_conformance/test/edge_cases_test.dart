import 'package:openapi_conformance/openapi_conformance.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

void main() {
  final petStore = OpenApiSpec.fromString(petStoreYaml);
  final modern = OpenApiSpec.fromString(openApi31Json);

  Map<String, EdgeCase> byDescription(List<EdgeCase> cases) => {
    for (final edgeCase in cases) edgeCase.description: edgeCase,
  };

  test('conformsToSpec is truthful for every case', () {
    for (final spec in [petStore, modern]) {
      final validator = SchemaValidator(spec);
      for (var seed = 0; seed < 20; seed++) {
        final edgeCases = EdgeCases(spec, seed: seed);
        for (final operation in spec.operations) {
          for (final key in operation.responses.keys) {
            final status = int.tryParse(key) ?? 599;
            final response = operation.responseFor(status);
            final schema = response?.content.values.firstOrNull?.schema;
            if (schema == null) continue;
            for (final edgeCase in edgeCases.forResponse(
              operation.key,
              status: status,
            )) {
              final valid = validator
                  .validate(
                    schema,
                    edgeCase.value,
                    direction: SchemaDirection.response,
                  )
                  .isEmpty;
              expect(valid, edgeCase.conformsToSpec, reason: '$edgeCase');
            }
          }
        }
      }
    }
  });

  test('expected variants for a pet response', () {
    final cases = byDescription(
      EdgeCases(petStore, seed: 1).forResponse('getPet'),
    );
    expect(cases['optional property \$.tag omitted']!.conformsToSpec, isTrue);
    expect(cases['nullable \$.tag set to null']!.conformsToSpec, isTrue);
    expect(cases['nullable \$.owner set to null']!.conformsToSpec, isTrue);
    expect(cases['unknown enum value in \$.status']!.conformsToSpec, isFalse);
    expect(cases['unknown extra property in \$']!.conformsToSpec, isFalse);
    expect(cases['empty string in \$.name']!.conformsToSpec, isFalse);
    expect(cases['string \$.name at minLength (1)']!.conformsToSpec, isTrue);
    final long = cases['very long string (10,000 chars) in \$.name']!;
    expect(long.conformsToSpec, isTrue);
    expect((long.value! as Map<String, Object?>)['name'], hasLength(10000));
    expect(cases['large int64 value in \$.id']!.conformsToSpec, isTrue);
    expect(cases.keys, contains('unicode/emoji string in \$.name'));
    final omitted = cases['optional property \$.tag omitted']!;
    expect(omitted.path, r'$.tag');
    expect(
      (omitted.value! as Map<String, Object?>).containsKey('tag'),
      isFalse,
    );
  });

  test('array variants and nested paths', () {
    final cases = byDescription(
      EdgeCases(petStore, seed: 1).forResponse('listPets'),
    );
    expect(cases['array \$ empty']!.value, isEmpty);
    expect(cases['array \$ empty']!.conformsToSpec, isTrue);
    expect(cases.keys, contains('optional property \$[0].tag omitted'));
  });

  test('bounds, maxItems, maxLength and additionalProperties', () {
    final spec = OpenApiSpec.fromString('''
openapi: 3.1.0
info: {title: t, version: '1'}
paths: {}
components:
  schemas:
    Box:
      type: object
      additionalProperties: true
      required: [count, label, items, ratio, flag]
      properties:
        count: {type: integer, minimum: 0, maximum: 10}
        label: {type: string, maxLength: 5}
        items: {type: array, maxItems: 4, items: {type: integer}}
        ratio: {type: number, exclusiveMinimum: 0, maximum: 1}
        flag: {type: boolean}
        when: {type: string, format: date-time}
''');
    final cases = byDescription(EdgeCases(spec, seed: 4).forComponent('Box'));
    expect(cases['integer \$.count at minimum (0)']!.conformsToSpec, isTrue);
    expect(cases['integer \$.count at maximum (10)']!.conformsToSpec, isTrue);
    expect(cases['negative integer in \$.count']!.conformsToSpec, isFalse);
    expect(cases['string \$.label at maxLength (5)']!.conformsToSpec, isTrue);
    expect(
      cases['very long string (10,000 chars) in \$.label']!.conformsToSpec,
      isFalse,
    );
    expect(cases['array \$.items at maxItems (4)']!.conformsToSpec, isTrue);
    expect(cases['unknown extra property in \$']!.conformsToSpec, isTrue);
    expect(cases['zero in \$.ratio']!.conformsToSpec, isFalse);
    expect(cases.keys, anyElement(startsWith('boolean \$.flag set to')));
    expect(
      cases['date-time \$.when with offset and fractional seconds']!
          .conformsToSpec,
      isTrue,
    );
  });

  test('request bodies respect readOnly', () {
    final cases = EdgeCases(petStore, seed: 2).forRequestBody('createPet');
    expect(cases, isNotEmpty);
    expect(cases.map((c) => c.path), isNot(contains(r'$.id')));
    expect(EdgeCases(petStore).forRequestBody('getPet'), isEmpty);
  });

  test('deterministic, deduplicated and capped', () {
    List<String> run() => [
      for (final c in EdgeCases(petStore, seed: 9).forResponse('listPets'))
        '${c.description}=${c.value}',
    ];
    expect(run(), equals(run()));
    final descriptions = run().map((entry) => entry.split('=').first).toList();
    expect(descriptions.toSet().length, descriptions.length);
    expect(
      EdgeCases(petStore, seed: 9, maxCases: 3).forResponse('listPets'),
      hasLength(3),
    );
  });

  test('recursive schemas terminate', () {
    final cases = EdgeCases(modern, seed: 1).forComponent('Item');
    expect(cases, isNotEmpty);
    expect(cases.length, lessThanOrEqualTo(200));
  });

  test('unknown component throws', () {
    expect(() => EdgeCases(petStore).forComponent('Nope'), throwsArgumentError);
  });
}
