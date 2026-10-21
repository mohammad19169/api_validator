import 'package:api_validator/api_validator.dart';
import 'package:test/test.dart';

import 'support/specs.dart';

OpenApiSpec _spec31([Map<String, Object?> schemas = const {}]) =>
    OpenApiSpec.fromMap({
      'openapi': '3.1.0',
      'info': {'title': 't', 'version': '1'},
      'paths': <String, Object?>{},
      'components': {'schemas': schemas},
    });

void main() {
  final v30 = SchemaValidator(OpenApiSpec.fromString(petStoreYaml));
  final v31 = SchemaValidator(_spec31());

  List<String> keywords(List<SchemaError> errors) => [
    for (final error in errors) error.keyword,
  ];

  test('types, including integral doubles', () {
    expect(v31.isValid({'type': 'integer'}, 3), isTrue);
    expect(v31.isValid({'type': 'integer'}, 3.0), isTrue);
    expect(v31.isValid({'type': 'integer'}, 3.5), isFalse);
    expect(v31.isValid({'type': 'number'}, 3), isTrue);
    expect(v31.isValid({'type': 'boolean'}, 'true'), isFalse);
    expect(
      v31.isValid({
        'type': ['string', 'null'],
      }, null),
      isTrue,
    );
  });

  test('3.0 exclusive bounds are booleans, 3.1 are numbers', () {
    expect(v30.isValid({'minimum': 0, 'exclusiveMinimum': true}, 0), isFalse);
    expect(v31.isValid({'exclusiveMinimum': 0}, 0), isFalse);
    expect(v31.isValid({'exclusiveMaximum': 10}, 9.5), isTrue);
  });

  test('strings', () {
    final errors = v31.validate({
      'type': 'string',
      'minLength': 3,
      'maxLength': 4,
      'pattern': r'^\d+$',
    }, 'ab');
    expect(keywords(errors), ['minLength', 'pattern']);
    expect(v31.isValid({'maxLength': 1}, '😀'), isTrue);
  });

  test('formats', () {
    bool ok(String format, Object value) =>
        v31.isValid({'format': format}, value);
    expect(ok('date-time', '2024-05-01T10:00:00Z'), isTrue);
    expect(ok('date-time', '2024-05-01 10:00'), isFalse);
    expect(ok('date', '2024-02-29'), isTrue);
    expect(ok('date', '2023-02-29'), isFalse);
    expect(ok('uuid', '123e4567-e89b-12d3-a456-426614174000'), isTrue);
    expect(ok('email', 'a@b'), isFalse);
    expect(ok('uri', 'https://x.dev'), isTrue);
    expect(ok('uri', 'x.dev'), isFalse);
    expect(ok('ipv4', '256.1.1.1'), isFalse);
    expect(ok('ipv6', '::1'), isTrue);
    expect(ok('int32', 2147483648), isFalse);
    expect(ok('unknown-format', 'anything'), isTrue);
    final relaxed = SchemaValidator(_spec31(), validateFormats: false);
    expect(relaxed.isValid({'format': 'uuid'}, 'nope'), isTrue);
    final custom = SchemaValidator(
      _spec31(),
      customFormats: {'even': (value) => value is int && value.isEven},
    );
    expect(custom.isValid({'format': 'even'}, 3), isFalse);
  });

  test('arrays', () {
    final schema = {
      'type': 'array',
      'items': {'type': 'integer'},
      'minItems': 1,
      'maxItems': 3,
      'uniqueItems': true,
    };
    expect(v31.isValid(schema, [1, 2]), isTrue);
    expect(keywords(v31.validate(schema, <Object?>[])), ['minItems']);
    expect(keywords(v31.validate(schema, [1, 1])), ['uniqueItems']);
    expect(v31.validate(schema, [1, 'x']).single.path, r'$[1]');
    expect(
      v31.isValid(
        {
          'contains': {'const': 2},
        },
        [1, 3],
      ),
      isFalse,
    );
  });

  test('objects', () {
    final schema = {
      'type': 'object',
      'required': ['a'],
      'properties': {
        'a': {'type': 'string'},
      },
      'patternProperties': {
        r'^x-': {'type': 'integer'},
      },
      'additionalProperties': false,
    };
    expect(v31.isValid(schema, {'a': 'x', 'x-count': 1}), isTrue);
    final errors = v31.validate(schema, {'x-count': 'one', 'b': 1});
    expect(
      keywords(errors),
      containsAll(['required', 'type', 'additionalProperties']),
    );
    expect(
      v31
          .validate(
            {
              'properties': {
                'odd key': {'type': 'string'},
              },
            },
            {'odd key': 1},
          )
          .single
          .path,
      r"$['odd key']",
    );
  });

  test('undeclared properties are reported but can be disabled', () {
    final schema = {
      'type': 'object',
      'properties': {
        'a': {'type': 'string'},
      },
    };
    final error = v31.validate(schema, {'a': 'x', 'b': 1}).single;
    expect(error.isUndeclaredProperty, isTrue);
    expect(error.path, r'$.b');
    final quiet = SchemaValidator(_spec31(), reportUndeclaredProperties: false);
    expect(quiet.isValid(schema, {'a': 'x', 'b': 1}), isTrue);
    expect(v31.isValid({'type': 'object'}, {'free': 1}), isTrue);
  });

  test('allOf members contribute declared properties', () {
    final spec = OpenApiSpec.fromString(petStoreYaml);
    final validator = SchemaValidator(spec);
    final pet = spec.componentSchema('Pet');
    expect(validator.declaredProperties(pet), containsAll(['name', 'owner']));
    expect(validator.isValid(pet, {'id': 1, 'name': 'a', 'tag': 'b'}), isTrue);
  });

  test('anyOf, oneOf, not, if/then/else', () {
    final anyOf = {
      'anyOf': [
        {'type': 'string'},
        {'type': 'integer'},
      ],
    };
    expect(v31.isValid(anyOf, 1), isTrue);
    final failure = v31.validate(anyOf, true).single;
    expect(failure.keyword, 'anyOf');
    expect(failure.causes, isNotEmpty);
    final oneOf = {
      'oneOf': [
        {'type': 'number'},
        {'type': 'integer'},
      ],
    };
    expect(v31.validate(oneOf, 1).single.message, contains('exactly one'));
    expect(
      v31.isValid({
        'not': {'type': 'string'},
      }, 'x'),
      isFalse,
    );
    final conditional = {
      'if': {
        'properties': {
          'kind': {'const': 'a'},
        },
      },
      'then': {
        'required': ['a'],
      },
      'else': {
        'required': ['b'],
      },
    };
    expect(v31.isValid(conditional, {'kind': 'a', 'a': 1}), isTrue);
    expect(v31.isValid(conditional, {'kind': 'z', 'a': 1}), isFalse);
  });

  test('readOnly and writeOnly depend on direction', () {
    final schema = {
      'type': 'object',
      'required': ['id', 'password'],
      'properties': {
        'id': {'type': 'integer', 'readOnly': true},
        'password': {'type': 'string', 'writeOnly': true},
      },
    };
    expect(
      v31.isValid(schema, {
        'password': 'x',
      }, direction: SchemaDirection.request),
      isTrue,
    );
    expect(
      v31.isValid(schema, {'id': 1}, direction: SchemaDirection.response),
      isTrue,
    );
    expect(
      keywords(
        v31.validate(schema, {
          'id': 1,
          'password': 'x',
        }, direction: SchemaDirection.response),
      ),
      ['writeOnly'],
    );
  });

  test('recursive schemas terminate', () {
    final spec = _spec31({
      'Node': {
        'type': 'object',
        'properties': {
          'next': {r'$ref': '#/components/schemas/Node'},
          'value': {'type': 'integer'},
        },
      },
      'Loop': {r'$ref': '#/components/schemas/Loop'},
    });
    final validator = SchemaValidator(spec);
    final node = {
      'value': 1,
      'next': {
        'value': 2,
        'next': {'value': 'three'},
      },
    };
    expect(
      validator.validate(spec.componentSchema('Node'), node).single.path,
      r'$.next.next.value',
    );
    expect(validator.validate(spec.componentSchema('Loop'), 1), isEmpty);
  });

  test('boolean schemas and dependentRequired', () {
    expect(v31.isValid(true, 1), isTrue);
    expect(v31.isValid(false, 1), isFalse);
    expect(
      v31.isValid(
        {
          'dependentRequired': {
            'card': ['cvv'],
          },
        },
        {'card': '1'},
      ),
      isFalse,
    );
  });
}
