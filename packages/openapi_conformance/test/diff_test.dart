import 'dart:convert';

import 'package:openapi_conformance/src/diff/spec_diff.dart';
import 'package:openapi_conformance/src/spec/openapi_spec.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

Map<String, Object?> _pet({
  Map<String, Object?>? properties,
  List<String> required = const ['id', 'name'],
}) => {
  'type': 'object',
  'required': required,
  'properties':
      properties ??
      {
        'id': {'type': 'integer'},
        'name': {'type': 'string'},
        'status': {
          'type': 'string',
          'enum': ['available', 'sold'],
        },
        'owner': {r'$ref': '#/components/schemas/Owner'},
      },
};

OpenApiSpec _spec({
  Map<String, Object?>? pet,
  Map<String, Object?>? owner,
  List<Map<String, Object?>> parameters = const [],
  Map<String, Object?>? requestBody,
  Map<String, Object?>? responses,
  Map<String, Object?> extraPaths = const {},
  String version = '3.0.3',
}) => OpenApiSpec.fromMap(
  jsonDecode(
        jsonEncode({
          'openapi': version,
          'info': {'title': 't', 'version': '1'},
          'paths': {
            '/pets/{id}': {
              'put': {
                'operationId': 'updatePet',
                'parameters': [
                  {
                    'name': 'id',
                    'in': 'path',
                    'required': true,
                    'schema': {'type': 'integer'},
                  },
                  ...parameters,
                ],
                'requestBody': ?requestBody,
                'responses':
                    responses ??
                    {
                      '200': {
                        'description': 'ok',
                        'content': {
                          'application/json': {
                            'schema': {r'$ref': '#/components/schemas/Pet'},
                          },
                        },
                      },
                    },
              },
            },
            ...extraPaths,
          },
          'components': {
            'schemas': {
              'Pet': pet ?? _pet(),
              'Owner':
                  owner ??
                  {
                    'type': 'object',
                    'properties': {
                      'email': {'type': 'string'},
                    },
                  },
            },
          },
        }),
      )
      as Map<String, Object?>,
);

Map<String, Object?> _body(
  Map<String, Object?> schema, {
  bool required = true,
}) => {
  'required': required,
  'content': {
    'application/json': {'schema': schema},
  },
};

SpecChange _single(SpecDiff diff, String kind) =>
    diff.changes.singleWhere((change) => change.kind == kind);

void main() {
  test('identical specs have no changes', () {
    final diff = SpecDiff.compare(_spec(), _spec());
    expect(diff.isEmpty, isTrue);
    expect(diff.toText(), contains('No changes'));
  });

  test('identical real-world spec, including cycles, has no changes', () {
    final spec = OpenApiSpec.fromString(petStoreYaml);
    expect(SpecDiff.compare(spec, spec).changes, isEmpty);
    final modern = OpenApiSpec.fromString(openApi31Json);
    expect(SpecDiff.compare(modern, modern).changes, isEmpty);
  });

  group('operations', () {
    final extra = {
      '/pets': {
        'get': {
          'operationId': 'listPets',
          'responses': {
            '200': {'description': 'ok'},
          },
        },
      },
    };

    test('removed operation is breaking', () {
      final diff = SpecDiff.compare(_spec(extraPaths: extra), _spec());
      final change = _single(diff, 'operation-removed');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.operation, 'GET /pets');
      expect(diff.affecting('listPets'), [change]);
    });

    test('added operation is non-breaking', () {
      final diff = SpecDiff.compare(_spec(), _spec(extraPaths: extra));
      expect(_single(diff, 'operation-added').impact, ChangeImpact.nonBreaking);
      expect(diff.hasBreakingChanges, isFalse);
    });

    test('renamed path parameter is not a change', () {
      final renamed = OpenApiSpec.fromString(
        petStoreYaml.replaceAll('petId', 'id'),
      );
      final spec = OpenApiSpec.fromString(petStoreYaml);
      expect(SpecDiff.compare(spec, renamed).changes, isEmpty);
    });
  });

  group('parameters', () {
    const optional = {
      'name': 'q',
      'in': 'query',
      'schema': {'type': 'string'},
    };
    const required = {
      'name': 'q',
      'in': 'query',
      'required': true,
      'schema': {'type': 'string'},
    };

    test('new required parameter is breaking', () {
      final diff = SpecDiff.compare(_spec(), _spec(parameters: [required]));
      final change = _single(diff, 'parameter-added');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.location, 'request.query');
    });

    test('new optional parameter is non-breaking', () {
      final diff = SpecDiff.compare(_spec(), _spec(parameters: [optional]));
      expect(_single(diff, 'parameter-added').impact, ChangeImpact.nonBreaking);
    });

    test('parameter becoming required is breaking', () {
      final diff = SpecDiff.compare(
        _spec(parameters: [optional]),
        _spec(parameters: [required]),
      );
      expect(_single(diff, 'parameter-required').impact, ChangeImpact.breaking);
    });

    test('removed parameter is potentially breaking', () {
      final diff = SpecDiff.compare(_spec(parameters: [optional]), _spec());
      expect(
        _single(diff, 'parameter-removed').impact,
        ChangeImpact.potentiallyBreaking,
      );
    });
  });

  group('request body', () {
    final base = {
      'type': 'object',
      'required': ['name'],
      'properties': {
        'name': {'type': 'string'},
        'kind': {
          'type': 'string',
          'enum': ['cat', 'dog'],
        },
        'note': {'type': 'string'},
      },
    };

    Map<String, Object?> variant(void Function(Map<String, Object?>) edit) {
      final copy = jsonDecode(jsonEncode(base)) as Map<String, Object?>;
      edit(copy);
      return copy;
    }

    test('new required body field is breaking', () {
      final diff = SpecDiff.compare(
        _spec(requestBody: _body(base)),
        _spec(
          requestBody: _body(
            variant((s) {
              (s['properties']! as Map<String, Object?>)['age'] = {
                'type': 'integer',
              };
              s['required'] = ['name', 'age'];
            }),
          ),
        ),
      );
      final change = _single(diff, 'property-added');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.jsonPath, r'$.age');
    });

    test('optional field becoming required is breaking', () {
      final diff = SpecDiff.compare(
        _spec(requestBody: _body(base)),
        _spec(
          requestBody: _body(variant((s) => s['required'] = ['name', 'note'])),
        ),
      );
      expect(_single(diff, 'property-required').impact, ChangeImpact.breaking);
    });

    test('removed request property is potentially breaking', () {
      final diff = SpecDiff.compare(
        _spec(requestBody: _body(base)),
        _spec(
          requestBody: _body(
            variant(
              (s) => (s['properties']! as Map<String, Object?>).remove('note'),
            ),
          ),
        ),
      );
      expect(
        _single(diff, 'property-removed').impact,
        ChangeImpact.potentiallyBreaking,
      );
    });

    test('removed request enum value is breaking', () {
      final diff = SpecDiff.compare(
        _spec(requestBody: _body(base)),
        _spec(
          requestBody: _body(
            variant(
              (s) => (s['properties']! as Map<String, Object?>)['kind'] = {
                'type': 'string',
                'enum': ['cat'],
              },
            ),
          ),
        ),
      );
      final change = _single(diff, 'enum-value-removed');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.jsonPath, r'$.kind');
    });

    test('new required body and body becoming required are breaking', () {
      expect(
        _single(
          SpecDiff.compare(_spec(), _spec(requestBody: _body(base))),
          'request-body-added',
        ).impact,
        ChangeImpact.breaking,
      );
      expect(
        _single(
          SpecDiff.compare(
            _spec(requestBody: _body(base, required: false)),
            _spec(requestBody: _body(base)),
          ),
          'request-body-required',
        ).impact,
        ChangeImpact.breaking,
      );
    });

    test('removed request media type is breaking', () {
      final diff = SpecDiff.compare(
        _spec(requestBody: _body(base)),
        _spec(
          requestBody: {
            'content': {
              'application/xml': {'schema': base},
            },
          },
        ),
      );
      expect(_single(diff, 'media-type-removed').impact, ChangeImpact.breaking);
      expect(
        _single(diff, 'media-type-added').impact,
        ChangeImpact.nonBreaking,
      );
    });
  });

  group('response schema', () {
    test('removed response property is breaking', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>).remove('status');
      final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
      final change = _single(diff, 'property-removed');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.location, 'response.200.body');
      expect(change.jsonPath, r'$.status');
    });

    test('required property becoming optional is breaking', () {
      final diff = SpecDiff.compare(
        _spec(),
        _spec(pet: _pet(required: ['id'])),
      );
      final change = _single(diff, 'property-optional');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.jsonPath, r'$.name');
    });

    test('type change is breaking, deep through refs', () {
      final diff = SpecDiff.compare(
        _spec(),
        _spec(
          owner: {
            'type': 'object',
            'properties': {
              'email': {'type': 'integer'},
            },
          },
        ),
      );
      final change = _single(diff, 'type-changed');
      expect(change.impact, ChangeImpact.breaking);
      expect(change.jsonPath, r'$.owner.email');
    });

    test('integer to number is potentially breaking', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>)['id'] = {'type': 'number'};
      final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
      expect(
        _single(diff, 'type-changed').impact,
        ChangeImpact.potentiallyBreaking,
      );
    });

    test('becoming nullable is breaking in responses', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>)['name'] = {
        'type': 'string',
        'nullable': true,
      };
      final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
      expect(_single(diff, 'nullable-changed').impact, ChangeImpact.breaking);
    });

    test('3.1 type arrays with null count as nullable', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>)['name'] = {
        'type': ['string', 'null'],
      };
      final diff = SpecDiff.compare(
        _spec(version: '3.1.0'),
        _spec(pet: pet, version: '3.1.0'),
      );
      expect(_single(diff, 'nullable-changed').impact, ChangeImpact.breaking);
    });

    test('new response enum value is potentially breaking', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>)['status'] = {
        'type': 'string',
        'enum': ['available', 'sold', 'reserved'],
      };
      final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
      final change = _single(diff, 'enum-value-added');
      expect(change.impact, ChangeImpact.potentiallyBreaking);
      expect(change.message, contains('"reserved"'));
    });

    test('format and constraint changes are potentially breaking', () {
      final pet = _pet();
      (pet['properties']! as Map<String, Object?>)['name'] = {
        'type': 'string',
        'format': 'email',
        'maxLength': 10,
      };
      final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
      expect(
        _single(diff, 'format-changed').impact,
        ChangeImpact.potentiallyBreaking,
      );
      expect(
        _single(diff, 'constraint-changed').impact,
        ChangeImpact.potentiallyBreaking,
      );
    });

    test('allOf members are merged', () {
      final split = {
        'allOf': [
          {
            'type': 'object',
            'required': ['id'],
            'properties': {
              'id': {'type': 'integer'},
            },
          },
          {
            'type': 'object',
            'required': ['name'],
            'properties': {
              'name': {'type': 'string'},
              'status': {
                'type': 'string',
                'enum': ['available', 'sold'],
              },
              'owner': {r'$ref': '#/components/schemas/Owner'},
            },
          },
        ],
      };
      expect(SpecDiff.compare(_spec(), _spec(pet: split)).changes, isEmpty);
    });

    test('oneOf variants are matched by reference', () {
      Map<String, Object?> responses(List<String> refs) => {
        '200': {
          'description': 'ok',
          'content': {
            'application/json': {
              'schema': {
                'oneOf': [
                  for (final ref in refs)
                    {r'$ref': '#/components/schemas/$ref'},
                ],
              },
            },
          },
        },
      };
      final diff = SpecDiff.compare(
        _spec(responses: responses(['Pet'])),
        _spec(responses: responses(['Pet', 'Owner'])),
      );
      final change = _single(diff, 'variant-added');
      expect(change.impact, ChangeImpact.potentiallyBreaking);
      expect(change.message, contains('Owner'));
    });
  });

  group('responses', () {
    Map<String, Object?> statuses(List<String> codes) => {
      for (final code in codes) code: {'description': code},
    };

    test('removed and added statuses are potentially breaking', () {
      final diff = SpecDiff.compare(
        _spec(responses: statuses(['200', '404'])),
        _spec(responses: statuses(['200', '410'])),
      );
      expect(
        _single(diff, 'response-removed').impact,
        ChangeImpact.potentiallyBreaking,
      );
      expect(
        _single(diff, 'response-added').impact,
        ChangeImpact.potentiallyBreaking,
      );
    });

    test('removed response media type is breaking', () {
      final diff = SpecDiff.compare(
        _spec(),
        _spec(
          responses: {
            '200': {
              'description': 'ok',
              'content': {
                'text/plain': {
                  'schema': {'type': 'string'},
                },
              },
            },
          },
        ),
      );
      expect(_single(diff, 'media-type-removed').impact, ChangeImpact.breaking);
    });
  });

  test('reports render as text and JSON', () {
    final pet = _pet(required: ['id']);
    final diff = SpecDiff.compare(_spec(), _spec(pet: pet));
    expect(diff.toText(), contains('Breaking:'));
    expect(
      diff.toText(),
      contains(r'PUT /pets/{id} [response.200.body] $.name'),
    );
    final json = diff.toJson();
    expect((json['summary']! as Map<String, Object?>)['breaking'], 1);
    expect(diff.breaking.single.toJson()['kind'], 'property-optional');
  });
}
