import 'dart:math';

import 'package:collection/collection.dart';

import '../schema/schema_validator.dart';
import '../spec/openapi_spec.dart';
import 'regex_generator.dart';
import 'schema_tools.dart';
import 'values.dart';

const _equality = DeepCollectionEquality();
const _hardDepthLimit = 12;

/// Generates fake values that conform to the schemas of an [OpenApiSpec].
///
/// Use it to build mock responses and request bodies that never go stale:
///
/// ```dart
/// final fake = FakeData(spec, seed: 1);
/// final pet = fake.response('getPet');           // a valid 200 body
/// final newPet = fake.requestBody('createPet');  // a valid request body
/// final owner = fake.component('Owner');
/// ```
///
/// With a [seed], the same calls always produce the same values. Generated
/// values are checked with [SchemaValidator] and regenerated when needed;
/// `example`, `examples` and `default` values are used when
/// [preferExamples] is `true` and they are themselves valid.
final class FakeData {
  /// Creates a generator for [spec].
  FakeData(
    this.spec, {
    int? seed,
    this.preferExamples = true,
    this.maxDepth = 4,
    this.maxItems = 2,
    this.includeOptional = true,
  }) : _random = Random(seed),
       _tools = SchemaTools(spec),
       _validator = SchemaValidator(spec);

  /// The spec whose schemas are used.
  final OpenApiSpec spec;

  /// Whether valid `example`, `examples` and `default` values are used
  /// instead of generated ones.
  final bool preferExamples;

  /// Nesting depth after which only required properties and the minimum
  /// number of array items are generated. Keeps recursive schemas finite.
  final int maxDepth;

  /// Upper bound for generated array lengths, unless `minItems` is larger.
  final int maxItems;

  /// Whether optional properties are generated (up to [maxDepth]).
  final bool includeOptional;

  final Random _random;
  final SchemaTools _tools;
  final SchemaValidator _validator;
  late final RegexGenerator _regex = RegexGenerator(_random);

  /// A value conforming to [schema], a raw schema node from the spec.
  ///
  /// [direction] controls `readOnly` (left out of requests) and `writeOnly`
  /// (left out of responses) properties.
  Object? schema(
    Object? schema, {
    SchemaDirection direction = SchemaDirection.response,
  }) {
    Object? last;
    for (var attempt = 0; attempt < 8; attempt++) {
      final value = _generate(schema, direction, 0, null);
      if (_validator.isValid(schema, value, direction: direction)) {
        return value;
      }
      last = value;
    }
    return last;
  }

  /// A value conforming to `components.schemas[name]`.
  ///
  /// Throws an [ArgumentError] when the component does not exist.
  Object? component(
    String name, {
    SchemaDirection direction = SchemaDirection.response,
  }) {
    final node = spec.componentSchema(name);
    if (node == null) {
      throw ArgumentError.value(name, 'name', 'No such component schema');
    }
    return schema(node, direction: direction);
  }

  /// A response body for [operation] (an `operationId` or `METHOD /path`).
  ///
  /// Without [status], the first `2xx` response is used, otherwise the first
  /// declared one. Returns `null` when the response has no body schema.
  Object? response(String operation, {int? status, String? mediaType}) {
    final op = spec.requireOperation(operation);
    final declared = _tools.response(op, status);
    if (declared == null) {
      throw ArgumentError.value(
        status,
        'status',
        'No response declared for ${op.key}',
      );
    }
    final media = _tools.media(declared.content, mediaType);
    if (media == null) return null;
    if (preferExamples &&
        media.example != null &&
        _validator.isValid(
          media.schema,
          media.example,
          direction: SchemaDirection.response,
        )) {
      return deepCopy(media.example);
    }
    if (media.schema == null) return null;
    return schema(media.schema, direction: SchemaDirection.response);
  }

  /// A request body for [operation], or `null` when it declares none.
  Object? requestBody(String operation, {String? mediaType}) {
    final op = spec.requireOperation(operation);
    final body = op.requestBody;
    if (body == null) return null;
    final media = _tools.media(body.content, mediaType);
    if (media == null) return null;
    if (preferExamples &&
        media.example != null &&
        _validator.isValid(
          media.schema,
          media.example,
          direction: SchemaDirection.request,
        )) {
      return deepCopy(media.example);
    }
    if (media.schema == null) return null;
    return schema(media.schema, direction: SchemaDirection.request);
  }

  /// Headers for a response of [operation]: every declared header with a
  /// fake value, plus `content-type` when the response has content.
  Map<String, String> responseHeaders(String operation, {int? status}) {
    final op = spec.requireOperation(operation);
    final declared = _tools.response(op, status);
    if (declared == null) return const {};
    final headers = <String, String>{};
    final media = _tools.media(declared.content, null);
    if (media != null) headers['content-type'] = media.mediaType;
    for (final header in declared.headers.values) {
      if (header.name.toLowerCase() == 'content-type') continue;
      final value = schema(header.schema);
      headers[header.name] = switch (value) {
        null => '',
        final List<Object?> list => list.join(','),
        final Map<Object?, Object?> map => [
          for (final entry in map.entries) '${entry.key},${entry.value}',
        ].join(','),
        _ => '$value',
      };
    }
    return headers;
  }

  // ---------------------------------------------------------------------------

  Object? _generate(
    Object? raw,
    SchemaDirection direction,
    int depth,
    String? name,
  ) {
    if (depth > _hardDepthLimit) return null;
    if (raw == null || raw == true) return NamedValues.string(name, _random);
    if (raw == false) return null;
    if (raw is! Map<String, Object?>) return null;

    final flat = _tools.flatten(raw);
    if (flat is! Map<String, Object?>) return NamedValues.string(name, _random);
    final schema = flat;

    if (preferExamples) {
      for (final candidate in _examples(schema)) {
        if (_validator.isValid(raw, candidate, direction: direction)) {
          return deepCopy(candidate);
        }
      }
    }
    if (schema.containsKey('const')) return deepCopy(schema['const']);

    final enumValues = schema['enum'];
    if (enumValues is List<Object?> && enumValues.isNotEmpty) {
      final nonNull = enumValues.where((value) => value != null).toList();
      final pool = nonNull.isEmpty ? enumValues : nonNull;
      return deepCopy(pool[_random.nextInt(pool.length)]);
    }

    final alternatives = schema['oneOf'] ?? schema['anyOf'];
    if (alternatives is List<Object?> && alternatives.isNotEmpty) {
      return _alternative(raw, schema, alternatives, direction, depth, name);
    }

    final types = _tools.types(schema);
    final allowsNull = types.contains('null') || schema['nullable'] == true;
    final concrete = types.where((type) => type != 'null').toList();
    if (concrete.isEmpty) return null;
    if (allowsNull && depth >= maxDepth) return null;

    final type = concrete[_random.nextInt(concrete.length)];
    var value = _typed(type, schema, direction, depth, name);

    final not = schema['not'];
    if (not != null) {
      for (var i = 0; i < 6 && _validator.isValid(not, value); i++) {
        final other = concrete[_random.nextInt(concrete.length)];
        value = _typed(other, schema, direction, depth, name);
      }
    }

    if (schema.containsKey('if')) {
      final matches = _validator.isValid(schema['if'], value);
      final branch = matches ? schema['then'] : schema['else'];
      if (branch is Map<String, Object?> &&
          !_validator.isValid(branch, value, direction: direction)) {
        final combined = _tools.merge(
          Map.of(schema)
            ..remove('if')
            ..remove('then')
            ..remove('else'),
          _tools.flatten(branch)! as Map<String, Object?>,
        );
        value = _generate(combined, direction, depth, name);
      }
    }
    return value;
  }

  Iterable<Object?> _examples(Map<String, Object?> schema) sync* {
    if (schema.containsKey('example')) yield schema['example'];
    final examples = schema['examples'];
    if (examples is List<Object?>) yield* examples;
    if (schema.containsKey('default')) yield schema['default'];
  }

  Object? _alternative(
    Map<String, Object?> raw,
    Map<String, Object?> schema,
    List<Object?> alternatives,
    SchemaDirection direction,
    int depth,
    String? name,
  ) {
    final base = Map<String, Object?>.of(schema)
      ..remove('oneOf')
      ..remove('anyOf')
      ..remove('discriminator');
    final discriminator = schema['discriminator'];
    final start = _random.nextInt(alternatives.length);
    Object? last;
    for (var i = 0; i < alternatives.length; i++) {
      final branch = alternatives[(start + i) % alternatives.length];
      final flatBranch = _tools.flatten(branch);
      final combined = flatBranch is Map<String, Object?>
          ? _tools.merge(base, flatBranch)
          : base;
      var value = _generate(combined, direction, depth, name);
      if (discriminator is Map<String, Object?> &&
          value is Map<String, Object?>) {
        final property = discriminator['propertyName'];
        final tag = _tagFor(discriminator, branch);
        if (property is String && tag != null) {
          value = {...value, property: tag};
        }
      }
      if (_validator.isValid(schema, value, direction: direction) ||
          _validator.isValid(raw, value, direction: direction)) {
        return value;
      }
      last = value;
    }
    return last;
  }

  String? _tagFor(Map<String, Object?> discriminator, Object? branch) {
    if (branch is! Map<String, Object?>) return null;
    final ref = branch[r'$ref'];
    if (ref is! String) return null;
    final mapping = discriminator['mapping'];
    if (mapping is Map<String, Object?>) {
      for (final MapEntry(:key, :value) in mapping.entries) {
        if (value == ref || '#/components/schemas/$value' == ref) return key;
      }
    }
    return OpenApiSpec.schemaNameOf(ref);
  }

  Object? _typed(
    String type,
    Map<String, Object?> schema,
    SchemaDirection direction,
    int depth,
    String? name,
  ) => switch (type) {
    'object' => _object(schema, direction, depth),
    'array' => _array(schema, direction, depth, name),
    'integer' => _integer(schema, name),
    'number' => _number(schema, name),
    'boolean' => _random.nextBool(),
    'string' => _string(schema, name),
    _ => null,
  };

  Map<String, Object?> _object(
    Map<String, Object?> schema,
    SchemaDirection direction,
    int depth,
  ) {
    final properties = schema['properties'] is Map<String, Object?>
        ? schema['properties']! as Map<String, Object?>
        : const <String, Object?>{};
    final required = {
      for (final name in (schema['required'] as List<Object?>?) ?? const [])
        '$name',
    };
    final result = <String, Object?>{};
    bool skip(Object? propertySchema) =>
        (direction == SchemaDirection.request &&
            _tools.flag(propertySchema, 'readOnly')) ||
        (direction == SchemaDirection.response &&
            _tools.flag(propertySchema, 'writeOnly'));

    final shallow = depth >= maxDepth || !includeOptional;
    for (final MapEntry(key: name, value: propertySchema)
        in properties.entries) {
      if (skip(propertySchema)) continue;
      if (!required.contains(name) && shallow) continue;
      result[name] = _generate(propertySchema, direction, depth + 1, name);
    }
    for (final name in required) {
      if (result.containsKey(name) || properties.containsKey(name)) continue;
      result[name] = NamedValues.string(name, _random);
    }

    final minProperties = schema['minProperties'];
    final additional = schema['additionalProperties'];
    final wanted = minProperties is num ? minProperties.toInt() : 0;
    if (result.length < wanted) {
      for (final MapEntry(key: name, value: propertySchema)
          in properties.entries) {
        if (result.length >= wanted) break;
        if (result.containsKey(name) || skip(propertySchema)) continue;
        result[name] = _generate(propertySchema, direction, depth + 1, name);
      }
    }
    final patterns = schema['patternProperties'];
    var index = 1;
    while (result.length < wanted && additional != false) {
      var key = 'key$index';
      Object? valueSchema = additional is Map<String, Object?>
          ? additional
          : null;
      if (patterns is Map<String, Object?> && patterns.isNotEmpty) {
        final pattern = patterns.keys.first;
        key = _regex.generate(pattern) ?? key;
        valueSchema = patterns[pattern];
      }
      index++;
      if (result.containsKey(key)) {
        if (index > wanted + 20) break;
        continue;
      }
      result[key] = _generate(valueSchema, direction, depth + 1, key);
    }
    if (properties.isEmpty &&
        additional is Map<String, Object?> &&
        result.isEmpty &&
        !shallow) {
      result['key1'] = _generate(additional, direction, depth + 1, 'key1');
    }
    return result;
  }

  List<Object?> _array(
    Map<String, Object?> schema,
    SchemaDirection direction,
    int depth,
    String? name,
  ) {
    final minItems = (schema['minItems'] as num?)?.toInt() ?? 0;
    final maxAllowed = (schema['maxItems'] as num?)?.toInt();
    final prefix = schema['prefixItems'] is List<Object?>
        ? schema['prefixItems']! as List<Object?>
        : const <Object?>[];
    var upper = max(minItems, max(maxItems, prefix.length));
    if (maxAllowed != null) upper = min(upper, maxAllowed);
    var count = depth >= maxDepth
        ? minItems
        : max(minItems, min(upper, 1 + _random.nextInt(max(1, maxItems))));
    if (count < prefix.length && depth < maxDepth) {
      count = min(prefix.length, upper);
    }
    final items = schema['items'];
    final unique = schema['uniqueItems'] == true;
    final itemName = name == null
        ? null
        : (name.endsWith('s') ? name.substring(0, name.length - 1) : name);
    final result = <Object?>[];
    final contains = schema['contains'];
    if (contains != null && count > 0) {
      result.add(_generate(contains, direction, depth + 1, itemName));
    }
    var attempts = 0;
    while (result.length < count && attempts < count * 12 + 12) {
      attempts++;
      final index = result.length;
      final Object? itemSchema;
      if (index < prefix.length) {
        itemSchema = prefix[index];
      } else if (items is List<Object?>) {
        itemSchema = index < items.length ? items[index] : null;
      } else {
        itemSchema = items;
      }
      final value = _generate(itemSchema, direction, depth + 1, itemName);
      if (unique &&
          result.any((existing) => _equality.equals(existing, value))) {
        continue;
      }
      result.add(value);
    }
    return result;
  }

  (num?, bool, num?, bool) _bounds(Map<String, Object?> schema) {
    num? low = schema['minimum'] as num?;
    num? high = schema['maximum'] as num?;
    var lowExclusive = schema['exclusiveMinimum'] == true;
    var highExclusive = schema['exclusiveMaximum'] == true;
    final exclusiveMinimum = schema['exclusiveMinimum'];
    if (exclusiveMinimum is num && (low == null || exclusiveMinimum >= low)) {
      low = exclusiveMinimum;
      lowExclusive = true;
    }
    final exclusiveMaximum = schema['exclusiveMaximum'];
    if (exclusiveMaximum is num && (high == null || exclusiveMaximum <= high)) {
      high = exclusiveMaximum;
      highExclusive = true;
    }
    return (low, lowExclusive, high, highExclusive);
  }

  int _integer(Map<String, Object?> schema, String? name) {
    final (low, lowExclusive, high, highExclusive) = _bounds(schema);
    var (defaultLow, defaultHigh) = NamedValues.integerRange(name);
    if (schema['format'] == 'int32') {
      defaultLow = max(defaultLow, -2147483648);
      defaultHigh = min(defaultHigh, 2147483647);
    }
    var lo = low == null ? null : (lowExclusive ? low.floor() + 1 : low.ceil());
    var hi = high == null
        ? null
        : (highExclusive ? high.ceil() - 1 : high.floor());
    if (lo == null && hi == null) {
      lo = defaultLow;
      hi = defaultHigh;
    } else if (lo == null) {
      lo = min(hi!, max(defaultLow, hi - 100));
      if (lo > hi) lo = hi;
    } else if (hi == null) {
      hi = max(lo, defaultHigh);
      if (hi - lo > 1000) hi = lo + 100;
    }
    if (hi < lo) return lo;
    final multipleOf = schema['multipleOf'];
    if (multipleOf is num && multipleOf > 0) {
      final kLow = (lo / multipleOf).ceil();
      final kHigh = (hi / multipleOf).floor();
      final k = kHigh < kLow ? kLow : kLow + _random.nextInt(kHigh - kLow + 1);
      return (k * multipleOf).round();
    }
    final span = hi - lo;
    if (span <= 0) return lo;
    return lo + _random.nextInt(min(span, 1 << 31) + 1);
  }

  num _number(Map<String, Object?> schema, String? name) {
    final (low, lowExclusive, high, highExclusive) = _bounds(schema);
    final double lo = (low ?? (high == null ? 1 : high - 100)).toDouble();
    double hi = (high ?? (low == null ? 500 : low + 100)).toDouble();
    if (hi < lo) hi = lo;
    final multipleOf = schema['multipleOf'];
    if (multipleOf is num && multipleOf > 0) {
      var kLow = (lo / multipleOf).ceil();
      var kHigh = (hi / multipleOf).floor();
      if (lowExclusive && kLow * multipleOf <= lo) kLow++;
      if (highExclusive && kHigh * multipleOf >= hi) kHigh--;
      final k = kHigh < kLow ? kLow : kLow + _random.nextInt(kHigh - kLow + 1);
      final decimals = _decimals(multipleOf);
      return double.parse((k * multipleOf).toStringAsFixed(decimals));
    }
    bool inside(num value) =>
        (lowExclusive ? value > lo : value >= lo) &&
        (highExclusive ? value < hi : value <= hi);
    final candidate = double.parse(
      (lo + (hi - lo) * _random.nextDouble()).toStringAsFixed(2),
    );
    if (inside(candidate)) return candidate;
    final middle = (lo + hi) / 2;
    if (inside(middle)) return middle;
    return lowExclusive ? lo + (hi - lo) / 1000 + 1e-9 : lo;
  }

  int _decimals(num value) {
    final text = value.toString();
    final dot = text.indexOf('.');
    if (text.contains('e')) return 10;
    return dot < 0 ? 0 : text.length - dot - 1;
  }

  String _string(Map<String, Object?> schema, String? name) {
    final minLength = (schema['minLength'] as num?)?.toInt();
    final maxLength = (schema['maxLength'] as num?)?.toInt();
    final pattern = schema['pattern'];
    if (pattern is String) {
      final generated = _regex.generate(
        pattern,
        minLength: minLength,
        maxLength: maxLength,
      );
      if (generated != null) return generated;
    }
    final format = schema['format'];
    if (format is String) {
      final generated = FormatValues.generate(format, _random);
      if (generated != null) return _fitLength(generated, minLength, maxLength);
    }
    return _fitLength(NamedValues.string(name, _random), minLength, maxLength);
  }

  String _fitLength(String value, int? minLength, int? maxLength) {
    var runes = value.runes.toList();
    if (maxLength != null && runes.length > maxLength) {
      runes = runes.sublist(0, max(0, maxLength));
    }
    if (minLength != null && runes.length < minLength) {
      const filler = 'abcdefghijklmnopqrstuvwxyz';
      while (runes.length < minLength) {
        runes.add(filler.codeUnitAt(_random.nextInt(filler.length)));
      }
    }
    return String.fromCharCodes(runes);
  }
}
