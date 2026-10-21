import 'package:meta/meta.dart';

import '../schema/schema_error.dart';
import '../schema/schema_validator.dart';
import '../spec/openapi_spec.dart';
import 'fake_data.dart';
import 'schema_tools.dart';

/// One tricky variant of a valid value, for testing parsing code.
@immutable
final class EdgeCase {
  /// Creates an edge case.
  const EdgeCase({
    required this.description,
    required this.path,
    required this.value,
    required this.conformsToSpec,
  });

  /// What was changed, for example `optional property $.tag omitted`.
  final String description;

  /// JSON path of the changed value, for example `$.tag`.
  final String path;

  /// The whole document with the change applied.
  final Object? value;

  /// Whether [value] still conforms to the spec (strict mode).
  ///
  /// Variants that do not conform, such as an unknown enum value, check that
  /// your client tolerates API evolution. Variants that conform must always
  /// be handled without crashing.
  final bool conformsToSpec;

  @override
  String toString() => '${conformsToSpec ? 'valid' : 'invalid'}: $description';
}

/// Generates edge cases that stress-test code parsing API values.
///
/// Starting from a valid fake value (see [FakeData]), it produces variants
/// such as omitted optional properties, `null` in nullable fields, empty and
/// full arrays, boundary numbers, very long and unicode strings, unknown
/// enum values and unknown extra properties.
///
/// ```dart
/// for (final edgeCase in EdgeCases(spec, seed: 1).forResponse('getPet')) {
///   test(edgeCase.description, () {
///     expect(() => Pet.fromJson(edgeCase.value as Map<String, Object?>),
///         returnsNormally);
///   });
/// }
/// ```
final class EdgeCases {
  /// Creates a generator for [spec].
  EdgeCases(this.spec, {int? seed, this.maxCases = 200})
    : _seed = seed,
      _tools = SchemaTools(spec),
      _validator = SchemaValidator(spec),
      _lenient = SchemaValidator(spec, reportUndeclaredProperties: false);

  /// The spec whose schemas are used.
  final OpenApiSpec spec;

  /// Maximum number of edge cases returned per call.
  final int maxCases;

  final int? _seed;
  final SchemaTools _tools;
  final SchemaValidator _validator;
  final SchemaValidator _lenient;

  /// Edge cases for a raw schema node.
  List<EdgeCase> forSchema(
    Object? schema, {
    SchemaDirection direction = SchemaDirection.response,
  }) {
    final base = FakeData(
      spec,
      seed: _seed,
      maxItems: 2,
    ).schema(schema, direction: direction);
    final collector = _Collector(this, schema, base, direction);
    collector.walk(schema, base, const [], 0);
    return collector.cases;
  }

  /// Edge cases for `components.schemas[name]`.
  List<EdgeCase> forComponent(String name) {
    final node = spec.componentSchema(name);
    if (node == null) {
      throw ArgumentError.value(name, 'name', 'No such component schema');
    }
    return forSchema(node);
  }

  /// Edge cases for a response body of [operation] (`operationId` or
  /// `METHOD /path`). Without [status], the first `2xx` response is used.
  List<EdgeCase> forResponse(String operation, {int? status}) {
    final op = spec.requireOperation(operation);
    final response = _tools.response(op, status);
    final media = response == null
        ? null
        : _tools.media(response.content, null);
    if (media?.schema == null) return const [];
    return forSchema(media!.schema, direction: SchemaDirection.response);
  }

  /// Edge cases for the request body of [operation].
  List<EdgeCase> forRequestBody(String operation) {
    final op = spec.requireOperation(operation);
    final body = op.requestBody;
    final media = body == null ? null : _tools.media(body.content, null);
    if (media?.schema == null) return const [];
    return forSchema(media!.schema, direction: SchemaDirection.request);
  }
}

const _unicode = 'Zoë 👩‍💻 测试 العربية';
const _unknownEnum = 'UNKNOWN_FUTURE_VALUE';
const _unknownProperty = 'unexpectedField';
const _maxSafeInteger = 9007199254740991;

final class _Omit {
  const _Omit();
}

const _omit = _Omit();

final class _Collector {
  _Collector(this.owner, this.rootSchema, this.base, this.direction);

  final EdgeCases owner;
  final Object? rootSchema;
  final Object? base;
  final SchemaDirection direction;
  final List<EdgeCase> cases = [];
  final Set<String> _seen = {};

  SchemaTools get tools => owner._tools;

  bool get _full => cases.length >= owner.maxCases;

  String _path(List<Object> segments) {
    var path = JsonPath.root;
    for (final segment in segments) {
      path = segment is int
          ? JsonPath.index(path, segment)
          : JsonPath.property(path, '$segment');
    }
    return path;
  }

  void add(String description, List<Object> segments, Object? replacement) {
    if (_full || !_seen.add(description)) return;
    final value = _replace(base, segments, 0, replacement);
    cases.add(
      EdgeCase(
        description: description,
        path: _path(segments),
        value: value,
        conformsToSpec: owner._validator
            .validate(rootSchema, value, direction: direction)
            .isEmpty,
      ),
    );
  }

  Object? _replace(
    Object? node,
    List<Object> segments,
    int index,
    Object? replacement,
  ) {
    if (index == segments.length) return deepCopy(replacement);
    final segment = segments[index];
    if (node is Map && segment is String) {
      final copy = <String, Object?>{
        for (final entry in node.entries) '${entry.key}': deepCopy(entry.value),
      };
      if (index == segments.length - 1 && replacement is _Omit) {
        copy.remove(segment);
      } else {
        copy[segment] = _replace(
          node[segment],
          segments,
          index + 1,
          replacement,
        );
      }
      return copy;
    }
    if (node is List && segment is int && segment < node.length) {
      final copy = [for (final item in node) deepCopy(item)];
      copy[segment] = _replace(node[segment], segments, index + 1, replacement);
      return copy;
    }
    return deepCopy(node);
  }

  Map<String, Object?>? _node(Object? schema, Object? value) {
    var flat = tools.flatten(schema);
    for (var round = 0; round < 3 && flat is Map<String, Object?>; round++) {
      final alternatives = flat['oneOf'] ?? flat['anyOf'];
      if (alternatives is! List<Object?>) break;
      final rest = Map<String, Object?>.of(flat)
        ..remove('oneOf')
        ..remove('anyOf')
        ..remove('discriminator');
      Map<String, Object?>? chosen;
      for (final alternative in alternatives) {
        if (owner._lenient.isValid(alternative, value, direction: direction)) {
          final branch = tools.flatten(alternative);
          chosen = tools.merge(
            rest,
            branch is Map<String, Object?> ? branch : const {},
          );
          break;
        }
      }
      flat = chosen ?? rest;
    }
    return flat is Map<String, Object?> ? flat : null;
  }

  void walk(Object? schema, Object? value, List<Object> segments, int depth) {
    if (_full || depth > 10) return;
    final node = _node(schema, value);
    if (node == null) return;
    final path = _path(segments);
    if (value != null &&
        owner._lenient.isValid(schema, null, direction: direction)) {
      add('nullable $path set to null', segments, null);
    }

    switch (value) {
      case final Map<Object?, Object?> map:
        _object(node, map, segments, depth);
      case final List<Object?> list:
        _array(node, list, segments, depth);
      case final String string:
        _string(node, string, segments);
      case final int integer:
        _integer(node, integer, segments);
      case final double number:
        _number(node, number, segments);
      case final bool flag:
        add('boolean $path set to ${!flag}', segments, !flag);
    }
  }

  void _object(
    Map<String, Object?> node,
    Map<Object?, Object?> value,
    List<Object> segments,
    int depth,
  ) {
    final properties = node['properties'] is Map<String, Object?>
        ? node['properties']! as Map<String, Object?>
        : const <String, Object?>{};
    final required = {
      for (final name in (node['required'] as List<Object?>?) ?? const [])
        '$name',
    };
    for (final key in value.keys.map((key) => '$key')) {
      if (!required.contains(key)) {
        add('optional property ${_path([...segments, key])} omitted', [
          ...segments,
          key,
        ], _omit);
      }
    }
    if (!value.containsKey(_unknownProperty)) {
      add('unknown extra property in ${_path(segments)}', [
        ...segments,
        _unknownProperty,
      ], 'surprise');
    }
    for (final key in value.keys.map((key) => '$key')) {
      final propertySchema = properties[key];
      if (propertySchema == null) continue;
      walk(propertySchema, value[key], [...segments, key], depth + 1);
    }
  }

  void _array(
    Map<String, Object?> node,
    List<Object?> value,
    List<Object> segments,
    int depth,
  ) {
    final path = _path(segments);
    if (value.isNotEmpty) add('array $path empty', segments, const <Object?>[]);
    if (value.length > 1) {
      add('array $path with a single item', segments, [value.first]);
    }
    final maxItems = (node['maxItems'] as num?)?.toInt();
    if (maxItems != null &&
        maxItems <= 100 &&
        value.isNotEmpty &&
        value.length < maxItems) {
      add('array $path at maxItems ($maxItems)', segments, [
        for (var i = 0; i < maxItems; i++) value[i % value.length],
      ]);
    }
    if (value.isEmpty) return;
    final prefix = node['prefixItems'];
    final items = node['items'];
    final Object? itemSchema = prefix is List<Object?> && prefix.isNotEmpty
        ? prefix.first
        : items is List<Object?>
        ? (items.isEmpty ? null : items.first)
        : items;
    walk(itemSchema, value.first, [...segments, 0], depth + 1);
  }

  void _string(Map<String, Object?> node, String value, List<Object> segments) {
    final path = _path(segments);
    if (node['enum'] is List<Object?> || node.containsKey('const')) {
      add('unknown enum value in $path', segments, _unknownEnum);
      return;
    }
    final format = node['format'];
    if (format == 'date-time') {
      add(
        'date-time $path with offset and fractional seconds',
        segments,
        '2024-02-29T23:59:59.999+14:00',
      );
    }
    if (format != null || node.containsKey('pattern')) return;
    if (value.isNotEmpty) add('empty string in $path', segments, '');
    final minLength = (node['minLength'] as num?)?.toInt();
    if (minLength != null && minLength > 0 && minLength <= 100000) {
      add('string $path at minLength ($minLength)', segments, 'a' * minLength);
    }
    final maxLength = (node['maxLength'] as num?)?.toInt();
    if (maxLength != null && maxLength <= 100000) {
      add('string $path at maxLength ($maxLength)', segments, 'a' * maxLength);
    }
    add('very long string (10,000 chars) in $path', segments, 'x' * 10000);
    add('unicode/emoji string in $path', segments, _unicode);
  }

  (num?, num?) _bounds(Map<String, Object?> node, {required bool integer}) {
    num? low = node['minimum'] as num?;
    num? high = node['maximum'] as num?;
    final exclusiveMinimum = node['exclusiveMinimum'];
    final exclusiveMaximum = node['exclusiveMaximum'];
    final step = integer ? 1 : 0.001;
    if (exclusiveMinimum is num) {
      low = exclusiveMinimum + step;
    } else if (exclusiveMinimum == true && low != null) {
      low = low + step;
    }
    if (exclusiveMaximum is num) {
      high = exclusiveMaximum - step;
    } else if (exclusiveMaximum == true && high != null) {
      high = high - step;
    }
    return (low, high);
  }

  void _integer(Map<String, Object?> node, int value, List<Object> segments) {
    final path = _path(segments);
    if (node['enum'] is List<Object?>) {
      add('unknown enum value in $path', segments, 987654321);
      return;
    }
    final (low, high) = _bounds(node, integer: true);
    if (low != null) {
      add('integer $path at minimum ($low)', segments, low.ceil());
    }
    if (high != null) {
      add('integer $path at maximum ($high)', segments, high.floor());
    }
    if (value != 0) add('zero in $path', segments, 0);
    add('negative integer in $path', segments, -1);
    if (node['format'] != 'int32') {
      add('large int64 value in $path', segments, _maxSafeInteger);
    }
  }

  void _number(Map<String, Object?> node, double value, List<Object> segments) {
    final path = _path(segments);
    final (low, high) = _bounds(node, integer: false);
    if (low != null) {
      add('number $path at minimum ($low)', segments, low.toDouble());
    }
    if (high != null) {
      add('number $path at maximum ($high)', segments, high.toDouble());
    }
    if (value != 0) add('zero in $path', segments, 0.0);
    add('very small fraction in $path', segments, 0.000001);
    add('very large number in $path', segments, 1e15);
  }
}
