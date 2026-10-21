import 'package:openapi_conformance/openapi_conformance.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

void main() {
  group('loading', () {
    test('YAML and JSON documents', () {
      final yaml = OpenApiSpec.fromString(petStoreYaml);
      expect(yaml.version, OpenApiVersion.v30);
      expect(yaml.title, 'Pet Store');
      expect(yaml.apiVersion, '1.0.0');
      expect(yaml.basePaths, ['/v1']);
      final json = OpenApiSpec.fromString(openApi31Json);
      expect(json.version, OpenApiVersion.v31);
      expect(json.basePaths, ['']);
    });

    test('rejects Swagger 2 and garbage', () {
      expect(
        () => OpenApiSpec.fromMap({'swagger': '2.0'}),
        throwsA(
          isA<OpenApiSpecException>().having(
            (e) => e.message,
            'message',
            contains('Swagger 2.0'),
          ),
        ),
      );
      expect(
        () => OpenApiSpec.fromString('{not json'),
        throwsA(isA<OpenApiSpecException>()),
      );
      expect(
        () => OpenApiSpec.fromString('- a list'),
        throwsA(isA<OpenApiSpecException>()),
      );
      expect(
        () => OpenApiSpec.fromMap({'openapi': '4.0.0'}),
        throwsA(isA<OpenApiSpecException>()),
      );
    });

    test('fromFile reports missing files', () async {
      await expectLater(
        OpenApiSpec.fromFile('does/not/exist.yaml'),
        throwsA(isA<OpenApiSpecException>()),
      );
    }, testOn: 'vm');
  });

  group('operations', () {
    final spec = OpenApiSpec.fromString(petStoreYaml);

    test('are parsed with merged parameters', () {
      final getPet = spec.requireOperation('getPet');
      expect(getPet.key, 'GET /pets/{petId}');
      expect(getPet.parameters.single.name, 'petId');
      expect(getPet.parameters.single.required, isTrue);
      expect(spec.operation('get /pets/{petId}'), same(getPet));
      expect(spec.operation('nothing'), isNull);
      expect(() => spec.requireOperation('nothing'), throwsArgumentError);
    });

    test('security falls back to the global requirement', () {
      expect(spec.requireOperation('listPets').security!.single.schemes, [
        'bearer',
      ]);
      expect(spec.requireOperation('myPets').security, isEmpty);
    });

    test('response keys resolve exact, range, then default', () {
      final create = spec.requireOperation('createPet');
      expect(create.responseKeyFor(201), '201');
      expect(create.responseKeyFor(404), '4XX');
      expect(create.responseKeyFor(500), isNull);
      expect(spec.requireOperation('listPets').responseKeyFor(418), 'default');
    });

    test('pointers and refs', () {
      expect(
        spec.resolvePointer('#/components/schemas/Error'),
        isA<Map<String, Object?>>(),
      );
      expect(
        () => spec.resolvePointer('#/components/schemas/Nope'),
        throwsA(isA<OpenApiSpecException>()),
      );
      expect(
        () => spec.resolvePointer('other.yaml#/x'),
        throwsA(isA<OpenApiSpecException>()),
      );
      expect(OpenApiSpec.schemaNameOf('#/components/schemas/a~1b'), 'a/b');
    });
  });

  group('routing', () {
    test('server variables and base paths', () {
      final spec = OpenApiSpec.fromMap({
        'openapi': '3.0.0',
        'info': {'title': 't', 'version': '1'},
        'servers': [
          {
            'url': 'https://{region}.x.dev/{version}',
            'variables': {
              'region': {'default': 'eu'},
              'version': {'default': 'v2'},
            },
          },
          {'url': '/'},
        ],
        'paths': {
          '/a/{id}': {
            'get': {'responses': <String, Object?>{}},
          },
        },
      });
      final matcher = OperationMatcher(spec);
      expect(spec.basePaths, ['/v2', '']);
      expect(
        matcher.match('GET', Uri.parse('https://eu.x.dev/v2/a/1')),
        isA<RouteMatched>().having((m) => m.pathParameters, 'parameters', {
          'id': '1',
        }),
      );
      expect(matcher.match('get', Uri.parse('/a/x%20y')), isA<RouteMatched>());
      expect(matcher.match('GET', Uri.parse('/a')), isA<RouteNotFound>());
      expect(
        matcher.match('POST', Uri.parse('/a/1')),
        isA<RouteMethodNotAllowed>(),
      );
    });
  });

  test('MediaTypes', () {
    expect(MediaTypes.isJson('application/problem+json'), isTrue);
    expect(MediaTypes.isJson('text/html'), isFalse);
    expect(
      MediaTypes.select([
        'application/json',
      ], 'application/json; charset=utf-8'),
      'application/json',
    );
    expect(MediaTypes.select(['image/*'], 'image/png'), 'image/*');
    expect(
      MediaTypes.select(['text/plain', 'application/json'], null),
      'application/json',
    );
    expect(MediaTypes.select(['text/plain'], 'text/html'), isNull);
  });
}
