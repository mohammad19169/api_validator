import '../spec/media_type.dart';
import '../spec/openapi_spec.dart';
import '../spec/operation.dart';

/// Internal helpers shared by the fake data and edge case generators.
final class SchemaTools {
  /// Creates helpers that resolve references against [spec].
  SchemaTools(this.spec);

  /// The spec used to resolve references.
  final OpenApiSpec spec;

  bool get _isV30 => spec.version == OpenApiVersion.v30;

  /// Resolves `$ref`s and merges `allOf` members into one schema map.
  ///
  /// Returns `null` for `true`/missing schemas and the original value for
  /// anything that is not a map.
  Object? flatten(Object? schema, [Set<Object>? seen]) {
    if (schema is! Map<String, Object?>) return schema;
    final visited = seen ?? <Object>{};
    if (!visited.add(schema)) return const <String, Object?>{};
    final ref = schema[r'$ref'];
    if (ref is String) {
      final target = flatten(spec.resolvePointer(ref), visited);
      if (_isV30) {
        visited.remove(schema);
        return target;
      }
      final siblings = Map<String, Object?>.of(schema)..remove(r'$ref');
      final result = siblings.isEmpty
          ? target
          : merge(
              target is Map<String, Object?> ? target : const {},
              flatten(siblings, visited) as Map<String, Object?>,
            );
      visited.remove(schema);
      return result;
    }
    var result = <String, Object?>{};
    final allOf = schema['allOf'];
    if (allOf is List<Object?>) {
      for (final member in allOf) {
        final flat = flatten(member, visited);
        if (flat is Map<String, Object?>) result = merge(result, flat);
      }
    }
    final own = Map<String, Object?>.of(schema)..remove('allOf');
    result = merge(result, own, ownWins: true);
    visited.remove(schema);
    return result;
  }

  /// Merges two flattened schemas, keeping the stricter constraints.
  Map<String, Object?> merge(
    Map<String, Object?> a,
    Map<String, Object?> b, {
    bool ownWins = false,
  }) {
    final result = Map<String, Object?>.of(a);
    for (final MapEntry(:key, :value) in b.entries) {
      if (!result.containsKey(key)) {
        result[key] = value;
        continue;
      }
      final existing = result[key];
      switch (key) {
        case 'properties':
          final merged = Map<String, Object?>.of(
            existing is Map<String, Object?> ? existing : const {},
          );
          if (value is Map<String, Object?>) {
            for (final MapEntry(key: name, value: propertySchema)
                in value.entries) {
              final previous = merged[name];
              merged[name] = previous == null
                  ? propertySchema
                  : {
                      'allOf': [previous, propertySchema],
                    };
            }
          }
          result[key] = merged;
        case 'required':
          result[key] = {
            ...?(existing as List<Object?>?),
            ...?(value as List<Object?>?),
          }.toList();
        case 'type':
          result[key] = _intersectTypes(existing, value);
        case 'minimum' ||
            'minLength' ||
            'minItems' ||
            'minProperties' ||
            'minContains':
          if (existing is num && value is num) {
            result[key] = existing > value ? existing : value;
          } else {
            result[key] = value;
          }
        case 'maximum' ||
            'maxLength' ||
            'maxItems' ||
            'maxProperties' ||
            'maxContains':
          if (existing is num && value is num) {
            result[key] = existing < value ? existing : value;
          } else {
            result[key] = value;
          }
        case 'exclusiveMinimum':
          if (existing is num && value is num) {
            result[key] = existing > value ? existing : value;
          } else {
            result[key] = existing == true || value == true ? true : value;
          }
        case 'exclusiveMaximum':
          if (existing is num && value is num) {
            result[key] = existing < value ? existing : value;
          } else {
            result[key] = existing == true || value == true ? true : value;
          }
        case 'enum':
          if (existing is List<Object?> && value is List<Object?>) {
            final common = existing.where(value.contains).toList();
            result[key] = common.isEmpty ? value : common;
          } else {
            result[key] = value;
          }
        case 'nullable':
          result[key] = ownWins ? value : (existing == true && value == true);
        default:
          result[key] = value;
      }
    }
    return result;
  }

  Object? _intersectTypes(Object? a, Object? b) {
    List<String> list(Object? value) => value is String
        ? [value]
        : value is List<Object?>
        ? [for (final entry in value) '$entry']
        : const [];
    final left = list(a);
    final right = list(b);
    if (left.isEmpty) return b;
    if (right.isEmpty) return a;
    final common = <String>[
      for (final type in left)
        if (right.contains(type))
          type
        else if (type == 'number' && right.contains('integer'))
          'integer'
        else if (type == 'integer' && right.contains('number'))
          'integer',
    ];
    if (common.isEmpty) return b;
    final unique = common.toSet().toList();
    return unique.length == 1 ? unique.single : unique;
  }

  /// The types a flattened schema allows, inferring one when `type` is absent.
  List<String> types(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type is String) return [type];
    if (type is List<Object?>) return [for (final t in type) '$t'];
    if (schema.containsKey('properties') ||
        schema.containsKey('required') ||
        schema.containsKey('additionalProperties') ||
        schema.containsKey('patternProperties') ||
        schema.containsKey('minProperties')) {
      return const ['object'];
    }
    if (schema.containsKey('items') ||
        schema.containsKey('prefixItems') ||
        schema.containsKey('minItems')) {
      return const ['array'];
    }
    final format = schema['format'];
    if (format == 'int32' || format == 'int64') return const ['integer'];
    if (format == 'float' || format == 'double') return const ['number'];
    if (schema.containsKey('minimum') ||
        schema.containsKey('maximum') ||
        schema.containsKey('multipleOf') ||
        schema['exclusiveMinimum'] is num ||
        schema['exclusiveMaximum'] is num) {
      return const ['number'];
    }
    return const ['string'];
  }

  /// Whether [schema] (following references and `allOf`) sets [keyword] to
  /// `true`, as with `readOnly` and `writeOnly`.
  bool flag(Object? schema, String keyword, [Set<Object>? seen]) {
    if (schema is! Map<String, Object?>) return false;
    final visited = seen ?? <Object>{};
    if (!visited.add(schema)) return false;
    if (schema[keyword] == true) return true;
    final ref = schema[r'$ref'];
    if (ref is String && flag(spec.resolvePointer(ref), keyword, visited)) {
      return true;
    }
    final allOf = schema['allOf'];
    if (allOf is List<Object?>) {
      return allOf.any((member) => flag(member, keyword, visited));
    }
    return false;
  }

  /// The response key used when no status is requested: the first `2xx`
  /// (exact or `2XX`), otherwise the first declared key.
  String? defaultResponseKey(ApiOperation operation) {
    for (final key in operation.responses.keys) {
      if (key.startsWith('2')) return key;
    }
    return operation.responses.keys.isEmpty
        ? null
        : operation.responses.keys.first;
  }

  /// The response of [operation] for [status], or the default response.
  ApiResponse? response(ApiOperation operation, int? status) {
    if (status != null) return operation.responseFor(status);
    final key = defaultResponseKey(operation);
    return key == null ? null : operation.responses[key];
  }

  /// Picks a media type entry from [content], preferring [mediaType], then
  /// JSON, then the first entry.
  ApiMediaType? media(Map<String, ApiMediaType> content, String? mediaType) {
    if (content.isEmpty) return null;
    if (mediaType != null) {
      final key = MediaTypes.select(content.keys, mediaType);
      return key == null ? null : content[key];
    }
    for (final entry in content.values) {
      if (entry.isJson) return entry;
    }
    return content.values.first;
  }
}

/// Returns a deep copy of a JSON-like value.
Object? deepCopy(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries) '${entry.key}': deepCopy(entry.value),
    };
  }
  if (value is List) return [for (final item in value) deepCopy(item)];
  return value;
}
