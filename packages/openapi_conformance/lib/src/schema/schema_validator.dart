import 'package:collection/collection.dart';

import '../spec/openapi_spec.dart';
import 'formats.dart';
import 'schema_error.dart';

/// Which side of an exchange a value belongs to.
///
/// This decides how `readOnly` and `writeOnly` properties are treated.
enum SchemaDirection {
  /// A request value: `readOnly` properties must not be sent and are never
  /// required.
  request,

  /// A response value: `writeOnly` properties must not be returned and are
  /// never required.
  response,

  /// Neither; `readOnly` and `writeOnly` are ignored.
  none,
}

/// Validates a custom string `format`. Returns `true` when [value] is valid.
typedef FormatValidator = bool Function(Object? value);

const _equality = DeepCollectionEquality();

const _structuralKeywords = {
  'properties',
  'patternProperties',
  'additionalProperties',
  'allOf',
  'anyOf',
  'oneOf',
  'items',
  'required',
};

/// Validates JSON values against OpenAPI schemas.
///
/// Supports both OpenAPI 3.0 (`nullable`, boolean `exclusiveMinimum`, `$ref`
/// overriding siblings) and OpenAPI 3.1 (JSON Schema 2020-12 keywords such
/// as `prefixItems`, `const`, type arrays and `if`/`then`/`else`).
///
/// ```dart
/// final validator = SchemaValidator(spec);
/// final errors = validator.validate(spec.componentSchema('User'), json);
/// ```
final class SchemaValidator {
  /// Creates a validator that resolves `$ref`s against [spec].
  SchemaValidator(
    this.spec, {
    this.validateFormats = true,
    this.reportUndeclaredProperties = true,
    Map<String, FormatValidator> customFormats = const {},
  }) : _formats = {...builtInFormats, ...customFormats};

  /// The spec used to resolve references.
  final OpenApiSpec spec;

  /// Whether `format` keywords (`date-time`, `uuid`, ...) are checked.
  final bool validateFormats;

  /// Whether properties that an object schema does not declare are reported.
  ///
  /// Only applies to schemas that list `properties` and leave
  /// `additionalProperties` unspecified. Errors produced this way have
  /// [SchemaError.isUndeclaredProperty] set.
  final bool reportUndeclaredProperties;

  final Map<String, FormatValidator> _formats;
  final Map<String, RegExp> _patterns = {};

  /// Returns every way in which [value] fails to match [schema].
  ///
  /// An empty list means the value is valid. [path] is the JSON path used
  /// as prefix in error paths.
  List<SchemaError> validate(
    Object? schema,
    Object? value, {
    SchemaDirection direction = SchemaDirection.none,
    String path = JsonPath.root,
  }) {
    final run = _Run(this, direction);
    run.check(schema, value, path, top: true);
    return run.deduplicated();
  }

  /// Whether [value] matches [schema].
  bool isValid(
    Object? schema,
    Object? value, {
    SchemaDirection direction = SchemaDirection.none,
  }) => validate(schema, value, direction: direction).isEmpty;

  RegExp _pattern(String source) =>
      _patterns.putIfAbsent(source, () => RegExp(source, unicode: true));

  /// The property names that [schema] declares, following `$ref`, `allOf`,
  /// `anyOf` and `oneOf`.
  Set<String> declaredProperties(Object? schema) =>
      _declared(schema, <Object>{}).names;

  _Declared _declared(Object? schema, Set<Object> seen) {
    final result = _Declared();
    if (schema is! Map<String, Object?> || !seen.add(schema)) return result;
    final ref = schema[r'$ref'];
    if (ref is String) {
      result.addAll(_declared(spec.resolvePointer(ref), seen));
    }
    final properties = schema['properties'];
    if (properties is Map<String, Object?>) {
      result.names.addAll(properties.keys);
      result.describes = true;
    }
    final patterns = schema['patternProperties'];
    if (patterns is Map<String, Object?>) {
      result.patterns.addAll(patterns.keys);
      result.describes = true;
    }
    if (schema.containsKey('additionalProperties') ||
        schema.containsKey('unevaluatedProperties')) {
      result.open = true;
    }
    for (final keyword in const ['allOf', 'anyOf', 'oneOf']) {
      final members = schema[keyword];
      if (members is! List<Object?>) continue;
      for (final member in members) {
        result.addAll(_declared(member, seen));
      }
    }
    return result;
  }
}

final class _Declared {
  final Set<String> names = {};
  final Set<String> patterns = {};
  bool describes = false;
  bool open = false;

  void addAll(_Declared other) {
    names.addAll(other.names);
    patterns.addAll(other.patterns);
    describes = describes || other.describes;
    open = open || other.open;
  }
}

final class _Run {
  _Run(this.validator, this.direction);

  final SchemaValidator validator;
  final SchemaDirection direction;
  final List<SchemaError> errors = [];
  final Set<String> _activeRefs = {};

  OpenApiSpec get spec => validator.spec;

  bool get _isV30 => spec.version == OpenApiVersion.v30;

  List<SchemaError> deduplicated() {
    final seen = <String>{};
    return [
      for (final error in errors)
        if (seen.add('${error.path}|${error.keyword}|${error.message}')) error,
    ];
  }

  _Run _child() => _Run(validator, direction).._activeRefs.addAll(_activeRefs);

  void _error(
    String path,
    String keyword,
    String message, {
    Object? expected,
    Object? actual,
    bool undeclared = false,
    List<SchemaError> causes = const [],
  }) {
    errors.add(
      SchemaError(
        path: path,
        keyword: keyword,
        message: message,
        expected: expected,
        actual: actual,
        isUndeclaredProperty: undeclared,
        causes: causes,
      ),
    );
  }

  void check(Object? schema, Object? value, String path, {required bool top}) {
    if (schema == null || schema == true) return;
    if (schema == false) {
      _error(path, 'false', 'no value is allowed here');
      return;
    }
    if (schema is! Map<String, Object?>) return;

    final ref = schema[r'$ref'];
    if (ref is String) {
      final structural =
          !_isV30 && schema.keys.any(_structuralKeywords.contains);
      final guard = '$ref@$path';
      if (_activeRefs.add(guard)) {
        check(spec.resolvePointer(ref), value, path, top: top && !structural);
        _activeRefs.remove(guard);
      }
      if (_isV30) return;
    }

    if (value == null && schema['nullable'] == true) return;

    if (!_checkType(schema, value, path)) return;

    final enumValues = schema['enum'];
    if (enumValues is List<Object?> &&
        !enumValues.any((option) => _equality.equals(option, value))) {
      _error(
        path,
        'enum',
        'expected one of ${_list(enumValues)}, got ${_show(value)}',
        expected: enumValues,
        actual: value,
      );
    }
    if (schema.containsKey('const') &&
        !_equality.equals(schema['const'], value)) {
      _error(
        path,
        'const',
        'expected ${_show(schema['const'])}, got ${_show(value)}',
        expected: schema['const'],
        actual: value,
      );
    }

    switch (value) {
      case final String string:
        _checkString(schema, string, path);
      case final num number:
        _checkNumber(schema, number, path);
      case final List<Object?> list:
        _checkArray(schema, list, path);
      case final Map<Object?, Object?> map:
        _checkObject(schema, map, path, top: top);
    }

    _checkCombinators(schema, value, path);
  }

  bool _checkType(Map<String, Object?> schema, Object? value, String path) {
    final rawType = schema['type'];
    final List<String> types;
    if (rawType is String) {
      types = [rawType];
    } else if (rawType is List<Object?>) {
      types = [for (final t in rawType) t.toString()];
    } else {
      if (value == null &&
          _isV30 &&
          schema['nullable'] != true &&
          _hasTypedKeywords(schema) &&
          !_enumAllowsNull(schema)) {
        _error(path, 'nullable', 'got null but the schema is not nullable');
        return false;
      }
      return true;
    }
    if (types.any((type) => _isOfType(value, type))) return true;
    final expected = types.join(' or ');
    final suffix = value == null && _isV30 ? ' (add nullable: true?)' : '';
    _error(
      path,
      'type',
      'expected $expected, got ${_typeName(value)}$suffix',
      expected: expected,
      actual: value,
    );
    return false;
  }

  bool _enumAllowsNull(Map<String, Object?> schema) {
    final values = schema['enum'];
    return values is List<Object?> && values.contains(null);
  }

  bool _hasTypedKeywords(Map<String, Object?> schema) =>
      schema.containsKey('properties') ||
      schema.containsKey('items') ||
      schema.containsKey('format') ||
      schema.containsKey('enum');

  void _checkString(Map<String, Object?> schema, String value, String path) {
    final length = value.runes.length;
    final minLength = schema['minLength'];
    if (minLength is num && length < minLength) {
      _error(
        path,
        'minLength',
        'expected at least $minLength characters, got $length',
        expected: minLength,
        actual: value,
      );
    }
    final maxLength = schema['maxLength'];
    if (maxLength is num && length > maxLength) {
      _error(
        path,
        'maxLength',
        'expected at most $maxLength characters, got $length',
        expected: maxLength,
        actual: value,
      );
    }
    final pattern = schema['pattern'];
    if (pattern is String) {
      try {
        if (!validator._pattern(pattern).hasMatch(value)) {
          _error(
            path,
            'pattern',
            'expected to match /$pattern/, got ${_show(value)}',
            expected: pattern,
            actual: value,
          );
        }
      } on FormatException {
        // An unsupported regular expression is a spec problem; skip it.
      }
    }
    _checkFormat(schema, value, path);
  }

  void _checkFormat(Map<String, Object?> schema, Object value, String path) {
    if (!validator.validateFormats) return;
    final format = schema['format'];
    if (format is! String) return;
    final check = validator._formats[format];
    if (check == null) return;
    if (!check(value)) {
      _error(
        path,
        'format',
        'expected format "$format", got ${_show(value)}',
        expected: format,
        actual: value,
      );
    }
  }

  void _checkNumber(Map<String, Object?> schema, num value, String path) {
    final minimum = schema['minimum'];
    final maximum = schema['maximum'];
    final exclusiveMinimum = schema['exclusiveMinimum'];
    final exclusiveMaximum = schema['exclusiveMaximum'];
    if (minimum is num) {
      final exclusive = exclusiveMinimum == true;
      if (exclusive ? value <= minimum : value < minimum) {
        _error(
          path,
          'minimum',
          'expected ${exclusive ? '>' : '>='} $minimum, got $value',
          expected: minimum,
          actual: value,
        );
      }
    }
    if (maximum is num) {
      final exclusive = exclusiveMaximum == true;
      if (exclusive ? value >= maximum : value > maximum) {
        _error(
          path,
          'maximum',
          'expected ${exclusive ? '<' : '<='} $maximum, got $value',
          expected: maximum,
          actual: value,
        );
      }
    }
    if (exclusiveMinimum is num && value <= exclusiveMinimum) {
      _error(
        path,
        'exclusiveMinimum',
        'expected > $exclusiveMinimum, got $value',
        expected: exclusiveMinimum,
        actual: value,
      );
    }
    if (exclusiveMaximum is num && value >= exclusiveMaximum) {
      _error(
        path,
        'exclusiveMaximum',
        'expected < $exclusiveMaximum, got $value',
        expected: exclusiveMaximum,
        actual: value,
      );
    }
    final multipleOf = schema['multipleOf'];
    if (multipleOf is num && multipleOf > 0) {
      final quotient = value / multipleOf;
      if ((quotient - quotient.roundToDouble()).abs() > 1e-9) {
        _error(
          path,
          'multipleOf',
          'expected a multiple of $multipleOf, got $value',
          expected: multipleOf,
          actual: value,
        );
      }
    }
    _checkFormat(schema, value, path);
  }

  void _checkArray(
    Map<String, Object?> schema,
    List<Object?> value,
    String path,
  ) {
    final minItems = schema['minItems'];
    if (minItems is num && value.length < minItems) {
      _error(
        path,
        'minItems',
        'expected at least $minItems items, got ${value.length}',
        expected: minItems,
      );
    }
    final maxItems = schema['maxItems'];
    if (maxItems is num && value.length > maxItems) {
      _error(
        path,
        'maxItems',
        'expected at most $maxItems items, got ${value.length}',
        expected: maxItems,
      );
    }
    if (schema['uniqueItems'] == true) {
      outer:
      for (var i = 0; i < value.length; i++) {
        for (var j = i + 1; j < value.length; j++) {
          if (_equality.equals(value[i], value[j])) {
            _error(path, 'uniqueItems', 'items at index $i and $j are equal');
            break outer;
          }
        }
      }
    }
    var start = 0;
    final prefixItems = schema['prefixItems'];
    if (prefixItems is List<Object?>) {
      for (var i = 0; i < prefixItems.length && i < value.length; i++) {
        check(prefixItems[i], value[i], JsonPath.index(path, i), top: true);
      }
      start = prefixItems.length;
    }
    final items = schema['items'];
    if (items is List<Object?>) {
      for (var i = 0; i < items.length && i < value.length; i++) {
        check(items[i], value[i], JsonPath.index(path, i), top: true);
      }
    } else if (items != null) {
      for (var i = start; i < value.length; i++) {
        check(items, value[i], JsonPath.index(path, i), top: true);
      }
    }
    final contains = schema['contains'];
    if (contains != null) {
      var matches = 0;
      for (final item in value) {
        final child = _child()..check(contains, item, path, top: false);
        if (child.errors.isEmpty) matches++;
      }
      final minContains = schema['minContains'] is num
          ? schema['minContains']! as num
          : 1;
      final maxContains = schema['maxContains'];
      if (matches < minContains) {
        _error(
          path,
          'contains',
          'expected at least $minContains matching items, got $matches',
        );
      }
      if (maxContains is num && matches > maxContains) {
        _error(
          path,
          'maxContains',
          'expected at most $maxContains matching items, got $matches',
        );
      }
    }
  }

  void _checkObject(
    Map<String, Object?> schema,
    Map<Object?, Object?> value,
    String path, {
    required bool top,
  }) {
    final properties = schema['properties'] is Map<String, Object?>
        ? schema['properties']! as Map<String, Object?>
        : const <String, Object?>{};

    final required = schema['required'];
    if (required is List<Object?>) {
      for (final name in required) {
        if (name is! String || value.containsKey(name)) continue;
        final propertySchema = properties[name];
        if (direction == SchemaDirection.request &&
            _flag(propertySchema, 'readOnly')) {
          continue;
        }
        if (direction == SchemaDirection.response &&
            _flag(propertySchema, 'writeOnly')) {
          continue;
        }
        _error(
          JsonPath.property(path, name),
          'required',
          'required property "$name" is missing',
          expected: name,
        );
      }
    }

    final count = value.length;
    final minProperties = schema['minProperties'];
    if (minProperties is num && count < minProperties) {
      _error(
        path,
        'minProperties',
        'expected at least $minProperties properties, got $count',
      );
    }
    final maxProperties = schema['maxProperties'];
    if (maxProperties is num && count > maxProperties) {
      _error(
        path,
        'maxProperties',
        'expected at most $maxProperties properties, got $count',
      );
    }

    final dependentRequired = schema['dependentRequired'];
    if (dependentRequired is Map<String, Object?>) {
      for (final MapEntry(:key, value: dependents)
          in dependentRequired.entries) {
        if (!value.containsKey(key) || dependents is! List<Object?>) continue;
        for (final dependent in dependents) {
          if (!value.containsKey(dependent)) {
            _error(
              JsonPath.property(path, '$dependent'),
              'dependentRequired',
              'property "$dependent" is required when "$key" is present',
            );
          }
        }
      }
    }

    final patternProperties =
        schema['patternProperties'] is Map<String, Object?>
        ? schema['patternProperties']! as Map<String, Object?>
        : const <String, Object?>{};
    final additional = schema['additionalProperties'];
    final propertyNames = schema['propertyNames'];

    for (final MapEntry(key: rawKey, value: propertyValue) in value.entries) {
      final key = '$rawKey';
      final propertyPath = JsonPath.property(path, key);
      if (propertyNames != null) {
        check(propertyNames, key, propertyPath, top: false);
      }
      var matched = false;
      if (properties.containsKey(key)) {
        matched = true;
        final propertySchema = properties[key];
        if (direction == SchemaDirection.request &&
            _flag(propertySchema, 'readOnly')) {
          _error(
            propertyPath,
            'readOnly',
            'read-only property "$key" must not be sent in a request',
          );
        } else if (direction == SchemaDirection.response &&
            _flag(propertySchema, 'writeOnly')) {
          _error(
            propertyPath,
            'writeOnly',
            'write-only property "$key" must not be returned in a response',
          );
        }
        check(propertySchema, propertyValue, propertyPath, top: true);
      }
      for (final MapEntry(key: pattern, value: patternSchema)
          in patternProperties.entries) {
        bool hit;
        try {
          hit = validator._pattern(pattern).hasMatch(key);
        } on FormatException {
          hit = false;
        }
        if (hit) {
          matched = true;
          check(patternSchema, propertyValue, propertyPath, top: true);
        }
      }
      if (matched) continue;
      if (additional == false) {
        _error(
          propertyPath,
          'additionalProperties',
          'property "$key" is not allowed',
          actual: propertyValue,
        );
      } else if (additional is Map<String, Object?>) {
        check(additional, propertyValue, propertyPath, top: true);
      }
    }

    if (top && validator.reportUndeclaredProperties && additional == null) {
      _reportUndeclared(schema, value, path);
    }
  }

  void _reportUndeclared(
    Map<String, Object?> schema,
    Map<Object?, Object?> value,
    String path,
  ) {
    final declared = validator._declared(schema, <Object>{});
    if (!declared.describes || declared.open) return;
    for (final rawKey in value.keys) {
      final key = '$rawKey';
      if (declared.names.contains(key)) continue;
      if (declared.patterns.any((pattern) {
        try {
          return validator._pattern(pattern).hasMatch(key);
        } on FormatException {
          return false;
        }
      })) {
        continue;
      }
      _error(
        JsonPath.property(path, key),
        'undeclared',
        'property "$key" is not declared in the schema',
        actual: value[rawKey],
        undeclared: true,
      );
    }
  }

  void _checkCombinators(
    Map<String, Object?> schema,
    Object? value,
    String path,
  ) {
    final allOf = schema['allOf'];
    if (allOf is List<Object?>) {
      for (final member in allOf) {
        check(member, value, path, top: false);
      }
    }

    final discriminated = _discriminatorTarget(schema, value, path);
    if (discriminated != _noDiscriminator) {
      if (discriminated != null) check(discriminated, value, path, top: false);
    } else {
      final anyOf = schema['anyOf'];
      if (anyOf is List<Object?>) {
        _checkAlternatives('anyOf', anyOf, value, path);
      }
      final oneOf = schema['oneOf'];
      if (oneOf is List<Object?>) {
        _checkAlternatives('oneOf', oneOf, value, path);
      }
    }

    final not = schema['not'];
    if (not != null) {
      final child = _child()..check(not, value, path, top: false);
      if (child.errors.isEmpty) {
        _error(path, 'not', 'value must not match the "not" schema');
      }
    }

    if (schema.containsKey('if')) {
      final condition = _child()..check(schema['if'], value, path, top: false);
      final branch = condition.errors.isEmpty ? schema['then'] : schema['else'];
      if (branch != null) check(branch, value, path, top: false);
    }
  }

  static const Object _noDiscriminator = Object();

  /// Returns the schema selected by `discriminator`, `null` when the
  /// discriminator failed (an error has been recorded), or
  /// [_noDiscriminator] when no discriminator applies.
  Object? _discriminatorTarget(
    Map<String, Object?> schema,
    Object? value,
    String path,
  ) {
    final discriminator = schema['discriminator'];
    if (discriminator is! Map<String, Object?>) return _noDiscriminator;
    final alternatives = schema['oneOf'] ?? schema['anyOf'];
    if (alternatives is! List<Object?>) return _noDiscriminator;
    final propertyName = discriminator['propertyName'];
    if (propertyName is! String || value is! Map<Object?, Object?>) {
      return _noDiscriminator;
    }
    final tag = value[propertyName];
    final tagPath = JsonPath.property(path, propertyName);
    if (tag is! String) {
      _error(
        tagPath,
        'discriminator',
        'discriminator property "$propertyName" is missing or not a string',
      );
      return null;
    }
    final mapping = discriminator['mapping'] is Map<String, Object?>
        ? discriminator['mapping']! as Map<String, Object?>
        : const <String, Object?>{};
    final mapped = mapping[tag];
    final targetRef = mapped is String
        ? (mapped.startsWith('#') ? mapped : '#/components/schemas/$mapped')
        : '#/components/schemas/$tag';
    for (final alternative in alternatives) {
      if (alternative is Map<String, Object?> &&
          alternative[r'$ref'] == targetRef) {
        return alternative;
      }
    }
    if (mapping.isEmpty) return _noDiscriminator;
    _error(
      tagPath,
      'discriminator',
      'unknown discriminator value ${_show(tag)}; expected one of '
          '${_list(mapping.keys.toList())}',
      expected: mapping.keys.toList(),
      actual: tag,
    );
    return null;
  }

  void _checkAlternatives(
    String keyword,
    List<Object?> alternatives,
    Object? value,
    String path,
  ) {
    var matches = 0;
    List<SchemaError>? closest;
    for (final alternative in alternatives) {
      final child = _child()..check(alternative, value, path, top: false);
      if (child.errors.isEmpty) {
        matches++;
      } else if (closest == null || child.errors.length < closest.length) {
        closest = child.errors;
      }
    }
    if (matches == 0) {
      final hint = closest == null || closest.isEmpty
          ? ''
          : '; closest alternative failed with: ${closest.first}';
      _error(
        path,
        keyword,
        'value does not match any of the ${alternatives.length} '
        '$keyword schemas$hint',
        causes: closest ?? const [],
      );
    } else if (keyword == 'oneOf' && matches > 1) {
      _error(
        path,
        keyword,
        'value matches $matches oneOf schemas but must match exactly one',
      );
    }
  }

  bool _flag(Object? schema, String keyword) {
    Object? current = schema;
    final seen = <Object>{};
    while (current is Map<String, Object?> && seen.add(current)) {
      if (current[keyword] == true) return true;
      final ref = current[r'$ref'];
      if (ref is! String) {
        final allOf = current['allOf'];
        if (allOf is List<Object?>) {
          return allOf.any((member) => _flag(member, keyword));
        }
        return false;
      }
      current = spec.resolvePointer(ref);
    }
    return false;
  }
}

bool _isOfType(Object? value, String type) => switch (type) {
  'null' => value == null,
  'boolean' => value is bool,
  'string' => value is String,
  'number' => value is num,
  'integer' => value is int || (value is double && _isIntegral(value)),
  'array' => value is List,
  'object' => value is Map,
  _ => true,
};

bool _isIntegral(double value) =>
    value.isFinite && value == value.truncateToDouble();

String _typeName(Object? value) => switch (value) {
  null => 'null',
  bool() => 'boolean',
  int() => 'integer',
  final double d => _isIntegral(d) ? 'integer' : 'number',
  String() => 'string',
  List() => 'array',
  Map() => 'object',
  _ => value.runtimeType.toString(),
};

String _show(Object? value) {
  if (value is String) {
    final text = value.length > 60 ? '${value.substring(0, 57)}...' : value;
    return '"$text"';
  }
  if (value is Map) return 'an object';
  if (value is List) return 'an array of ${value.length}';
  return '$value';
}

String _list(List<Object?> values) {
  final shown = values.take(8).map(_show).join(', ');
  return values.length > 8 ? '[$shown, ...]' : '[$shown]';
}
