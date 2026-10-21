import 'package:meta/meta.dart';

import '../schema/schema_error.dart';
import '../spec/media_type.dart';
import '../spec/openapi_spec.dart';
import '../spec/operation.dart';

/// How a spec change affects an existing client of the API.
enum ChangeImpact {
  /// Existing clients will break, for example a response property was
  /// removed or changed type.
  breaking,

  /// Existing clients may break depending on how they are written, for
  /// example a new enum value in a response.
  potentiallyBreaking,

  /// Existing clients keep working, for example a new operation.
  nonBreaking,
}

/// One difference between two versions of a spec.
@immutable
final class SpecChange {
  /// Creates a change.
  const SpecChange({
    required this.impact,
    required this.kind,
    required this.message,
    this.operation,
    this.location,
    this.jsonPath,
  });

  /// How the change affects clients.
  final ChangeImpact impact;

  /// Machine readable kind, for example `property-removed`.
  final String kind;

  /// The affected operation key (`GET /users/{id}`), if any.
  final String? operation;

  /// Where in the operation the change is, for example `request.query` or
  /// `response.200.body`.
  final String? location;

  /// JSON path inside a body schema, for example `$.owner.email`.
  final String? jsonPath;

  /// Human readable description.
  final String message;

  /// Whether [impact] is [ChangeImpact.breaking].
  bool get isBreaking => impact == ChangeImpact.breaking;

  /// Serializes this change.
  Map<String, Object?> toJson() => {
    'impact': impact.name,
    'kind': kind,
    'operation': ?operation,
    'location': ?location,
    'jsonPath': ?jsonPath,
    'message': message,
  };

  @override
  String toString() {
    final buffer = StringBuffer();
    if (operation != null) buffer.write('$operation ');
    if (location != null) buffer.write('[$location] ');
    if (jsonPath != null) buffer.write('$jsonPath: ');
    buffer.write(message);
    return buffer.toString();
  }
}

/// The differences between two versions of a spec, classified from the
/// point of view of an existing client (for example a released app).
///
/// ```dart
/// final diff = SpecDiff.compare(oldSpec, newSpec);
/// if (diff.hasBreakingChanges) print(diff.toText());
/// ```
@immutable
final class SpecDiff {
  SpecDiff._(this.changes, this._operationIds);

  /// Compares [before] with [after].
  static SpecDiff compare(OpenApiSpec before, OpenApiSpec after) {
    final differ = _Differ(before, after)..run();
    return SpecDiff._(List.unmodifiable(differ.changes), differ.operationIds);
  }

  /// Every change found, in a stable order.
  final List<SpecChange> changes;

  final Map<String, String> _operationIds;

  /// Changes with [ChangeImpact.breaking].
  List<SpecChange> get breaking => _withImpact(ChangeImpact.breaking);

  /// Changes with [ChangeImpact.potentiallyBreaking].
  List<SpecChange> get potentiallyBreaking =>
      _withImpact(ChangeImpact.potentiallyBreaking);

  /// Changes with [ChangeImpact.nonBreaking].
  List<SpecChange> get nonBreaking => _withImpact(ChangeImpact.nonBreaking);

  /// Whether any change is breaking.
  bool get hasBreakingChanges => changes.any((change) => change.isBreaking);

  /// Whether nothing changed.
  bool get isEmpty => changes.isEmpty;

  List<SpecChange> _withImpact(ChangeImpact impact) => [
    for (final change in changes)
      if (change.impact == impact) change,
  ];

  /// Changes concerning [operation], given as `operationId` or
  /// `METHOD /path`.
  List<SpecChange> affecting(String operation) {
    final key =
        _operationIds[operation.trim()] ?? _normalizeReference(operation);
    return [
      for (final change in changes)
        if (change.operation != null &&
            (change.operation == key ||
                _normalizeReference(change.operation!) == key))
          change,
    ];
  }

  /// A readable report grouped by impact.
  String toText() {
    if (changes.isEmpty) return 'No changes between the two specs.';
    final buffer = StringBuffer(
      '${changes.length} change${changes.length == 1 ? '' : 's'}: '
      '${breaking.length} breaking, '
      '${potentiallyBreaking.length} potentially breaking, '
      '${nonBreaking.length} non-breaking\n',
    );
    for (final (title, group) in [
      ('Breaking', breaking),
      ('Potentially breaking', potentiallyBreaking),
      ('Non-breaking', nonBreaking),
    ]) {
      if (group.isEmpty) continue;
      buffer.writeln('\n$title:');
      for (final change in group) {
        buffer.writeln('  - $change');
      }
    }
    return buffer.toString().trimRight();
  }

  /// Serializes the diff.
  Map<String, Object?> toJson() => {
    'summary': {
      'breaking': breaking.length,
      'potentiallyBreaking': potentiallyBreaking.length,
      'nonBreaking': nonBreaking.length,
    },
    'changes': [for (final change in changes) change.toJson()],
  };
}

String _normalizeReference(String reference) {
  final trimmed = reference.trim();
  final space = trimmed.indexOf(' ');
  if (space < 0) return trimmed;
  return '${trimmed.substring(0, space).toUpperCase()} '
      '${trimmed.substring(space + 1).trim()}';
}

/// Path template with parameter names erased, so `/pets/{id}` and
/// `/pets/{petId}` are treated as the same path.
String _shape(ApiOperation operation) =>
    '${operation.method} ${operation.path.replaceAll(RegExp(r'\{[^}]*\}'), '{}')}';

enum _Direction { request, response }

const _constraintKeywords = [
  'minLength',
  'maxLength',
  'pattern',
  'minimum',
  'maximum',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'multipleOf',
  'minItems',
  'maxItems',
  'uniqueItems',
  'minProperties',
  'maxProperties',
];

const _maxDepth = 16;

/// A schema with `$ref` resolved and `allOf` members merged.
final class _View {
  final Set<String> types = {};
  bool nullable = false;
  final Map<String, Object?> properties = {};
  final Set<String> required = {};
  List<Object?>? enumValues;
  String? format;
  Object? items;
  Object? additionalProperties;
  final Map<String, Object?> constraints = {};
  List<Object?>? oneOf;
  List<Object?>? anyOf;
  bool readOnly = false;
  bool writeOnly = false;
}

final class _Differ {
  _Differ(this.before, this.after);

  final OpenApiSpec before;
  final OpenApiSpec after;
  final List<SpecChange> changes = [];
  final Map<String, String> operationIds = {};

  String? _operation;
  String? _location;

  void _add(
    ChangeImpact impact,
    String kind,
    String message, {
    String? jsonPath,
  }) => changes.add(
    SpecChange(
      impact: impact,
      kind: kind,
      message: message,
      operation: _operation,
      location: _location,
      jsonPath: jsonPath,
    ),
  );

  void run() {
    final beforeOps = {for (final op in before.operations) _shape(op): op};
    final afterOps = {for (final op in after.operations) _shape(op): op};
    for (final op in [...before.operations, ...after.operations]) {
      if (op.operationId != null) operationIds[op.operationId!] = op.key;
    }
    for (final MapEntry(key: shape, value: old) in beforeOps.entries) {
      _operation = old.key;
      _location = null;
      final current = afterOps[shape];
      if (current == null) {
        _add(
          ChangeImpact.breaking,
          'operation-removed',
          'operation was removed',
        );
        continue;
      }
      _operation = current.key;
      _compareOperation(old, current);
    }
    for (final MapEntry(key: shape, value: added) in afterOps.entries) {
      if (beforeOps.containsKey(shape)) continue;
      _operation = added.key;
      _location = null;
      _add(ChangeImpact.nonBreaking, 'operation-added', 'operation was added');
    }
    _operation = null;
    _location = null;
  }

  void _compareOperation(ApiOperation old, ApiOperation current) {
    if (!old.deprecated && current.deprecated) {
      _location = null;
      _add(
        ChangeImpact.nonBreaking,
        'operation-deprecated',
        'operation is now deprecated',
      );
    }
    _compareParameters(old, current);
    _compareRequestBody(old.requestBody, current.requestBody);
    _compareResponses(old, current);
  }

  // ---------------------------------------------------------------------------
  // Parameters

  void _compareParameters(ApiOperation old, ApiOperation current) {
    String key(ApiParameter p) => p.location == ParameterLocation.header
        ? 'header:${p.name.toLowerCase()}'
        : '${p.location.name}:${p.name}';
    // Path parameters are matched by position since names may be renamed.
    final oldPath = [
      for (final p in old.parameters)
        if (p.location == ParameterLocation.path) p,
    ];
    final newPath = [
      for (final p in current.parameters)
        if (p.location == ParameterLocation.path) p,
    ];
    final oldByName = {for (final p in oldPath) p.name: p};
    for (final p in newPath) {
      final previous =
          oldByName[p.name] ??
          (oldPath.length == newPath.length
              ? oldPath[newPath.indexOf(p)]
              : null);
      if (previous == null) continue;
      _location = 'request.path';
      _compareSchema(
        previous.schema,
        p.schema,
        JsonPath.property(JsonPath.root, p.name),
        _Direction.request,
      );
    }

    final oldParams = {
      for (final p in old.parameters)
        if (p.location != ParameterLocation.path) key(p): p,
    };
    final newParams = {
      for (final p in current.parameters)
        if (p.location != ParameterLocation.path) key(p): p,
    };
    for (final MapEntry(key: name, value: previous) in oldParams.entries) {
      _location = 'request.${previous.location.name}';
      final next = newParams[name];
      if (next == null) {
        _add(
          ChangeImpact.potentiallyBreaking,
          'parameter-removed',
          'parameter "${previous.name}" was removed',
        );
        continue;
      }
      if (!previous.required && next.required) {
        _add(
          ChangeImpact.breaking,
          'parameter-required',
          'parameter "${next.name}" is now required',
        );
      }
      _compareSchema(
        previous.schema,
        next.schema,
        JsonPath.property(JsonPath.root, next.name),
        _Direction.request,
      );
    }
    for (final MapEntry(key: name, value: next) in newParams.entries) {
      if (oldParams.containsKey(name)) continue;
      _location = 'request.${next.location.name}';
      if (next.required) {
        _add(
          ChangeImpact.breaking,
          'parameter-added',
          'required parameter "${next.name}" was added',
        );
      } else {
        _add(
          ChangeImpact.nonBreaking,
          'parameter-added',
          'optional parameter "${next.name}" was added',
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Request body

  void _compareRequestBody(ApiRequestBody? old, ApiRequestBody? current) {
    _location = 'request.body';
    if (old == null && current == null) return;
    if (old == null) {
      _add(
        current!.required ? ChangeImpact.breaking : ChangeImpact.nonBreaking,
        'request-body-added',
        current.required
            ? 'a required request body was added'
            : 'an optional request body was added',
      );
      return;
    }
    if (current == null) {
      _add(
        ChangeImpact.potentiallyBreaking,
        'request-body-removed',
        'the request body was removed',
      );
      return;
    }
    if (!old.required && current.required) {
      _add(
        ChangeImpact.breaking,
        'request-body-required',
        'the request body is now required',
      );
    }
    for (final MapEntry(key: mediaType, value: media) in old.content.entries) {
      final next = _media(current.content, mediaType);
      if (next == null) {
        _add(
          ChangeImpact.breaking,
          'media-type-removed',
          'request media type "$mediaType" is no longer accepted',
        );
        continue;
      }
      _compareSchema(
        media.schema,
        next.schema,
        JsonPath.root,
        _Direction.request,
      );
    }
    for (final mediaType in current.content.keys) {
      if (_media(old.content, mediaType) != null) continue;
      _add(
        ChangeImpact.nonBreaking,
        'media-type-added',
        'request media type "$mediaType" is now accepted',
      );
    }
  }

  ApiMediaType? _media(Map<String, ApiMediaType> content, String mediaType) {
    final key = MediaTypes.select(content.keys, mediaType);
    if (key == null) return null;
    if (MediaTypes.essence(key) != MediaTypes.essence(mediaType)) return null;
    return content[key];
  }

  // ---------------------------------------------------------------------------
  // Responses

  void _compareResponses(ApiOperation old, ApiOperation current) {
    for (final MapEntry(key: status, value: response)
        in old.responses.entries) {
      _location = 'response.$status';
      final next = current.responses[status];
      if (next == null) {
        _add(
          ChangeImpact.potentiallyBreaking,
          'response-removed',
          'response $status was removed',
        );
        continue;
      }
      for (final MapEntry(key: mediaType, value: media)
          in response.content.entries) {
        _location = 'response.$status';
        final nextMedia = _media(next.content, mediaType);
        if (nextMedia == null) {
          _add(
            ChangeImpact.breaking,
            'media-type-removed',
            'response media type "$mediaType" was removed',
          );
          continue;
        }
        _location = 'response.$status.body';
        _compareSchema(
          media.schema,
          nextMedia.schema,
          JsonPath.root,
          _Direction.response,
        );
      }
      for (final mediaType in next.content.keys) {
        if (_media(response.content, mediaType) != null) continue;
        _location = 'response.$status';
        _add(
          ChangeImpact.nonBreaking,
          'media-type-added',
          'response media type "$mediaType" was added',
        );
      }
      for (final MapEntry(key: name, value: header) in next.headers.entries) {
        final previous = response.headers[name];
        _location = 'response.$status.header';
        if (previous != null && previous.required && !header.required) {
          _add(
            ChangeImpact.breaking,
            'header-optional',
            'response header "${header.name}" is no longer guaranteed',
          );
        }
      }
      for (final MapEntry(key: name, value: header)
          in response.headers.entries) {
        if (next.headers.containsKey(name)) continue;
        _location = 'response.$status.header';
        _add(
          header.required
              ? ChangeImpact.breaking
              : ChangeImpact.potentiallyBreaking,
          'header-removed',
          'response header "${header.name}" was removed',
        );
      }
    }
    for (final status in current.responses.keys) {
      if (old.responses.containsKey(status)) continue;
      _location = 'response.$status';
      _add(
        ChangeImpact.potentiallyBreaking,
        'response-added',
        'response $status was added',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Schemas

  final Set<(Object, Object)> _visiting = {};

  void _compareSchema(
    Object? oldSchema,
    Object? newSchema,
    String path,
    _Direction direction, [
    int depth = 0,
  ]) {
    if (depth > _maxDepth) return;
    if (oldSchema == null || newSchema == null) return;
    final pair = (oldSchema, newSchema);
    if (!_visiting.add(pair)) return;
    try {
      final old = _view(before, oldSchema);
      final next = _view(after, newSchema);
      _compareViews(old, next, path, direction, depth);
    } finally {
      _visiting.remove(pair);
    }
  }

  void _compareViews(
    _View old,
    _View next,
    String path,
    _Direction direction,
    int depth,
  ) {
    final isResponse = direction == _Direction.response;

    if (old.types.isNotEmpty &&
        next.types.isNotEmpty &&
        !_sameTypes(old.types, next.types)) {
      final numeric = _isNumeric(old.types) && _isNumeric(next.types);
      _add(
        numeric ? ChangeImpact.potentiallyBreaking : ChangeImpact.breaking,
        'type-changed',
        'type changed from ${old.types.join('|')} to ${next.types.join('|')}',
        jsonPath: path,
      );
      if (!numeric) return;
    }

    if (!old.nullable && next.nullable) {
      _add(
        isResponse ? ChangeImpact.breaking : ChangeImpact.nonBreaking,
        'nullable-changed',
        isResponse ? 'value may now be null' : 'value now accepts null',
        jsonPath: path,
      );
    } else if (old.nullable && !next.nullable) {
      _add(
        isResponse
            ? ChangeImpact.nonBreaking
            : ChangeImpact.potentiallyBreaking,
        'nullable-changed',
        isResponse ? 'value is no longer null' : 'null is no longer accepted',
        jsonPath: path,
      );
    }

    _compareEnums(old, next, path, isResponse);

    if (old.format != next.format &&
        (old.format != null || next.format != null)) {
      _add(
        ChangeImpact.potentiallyBreaking,
        'format-changed',
        'format changed from ${old.format ?? '(none)'} to '
            '${next.format ?? '(none)'}',
        jsonPath: path,
      );
    }

    for (final keyword in _constraintKeywords) {
      final a = old.constraints[keyword];
      final b = next.constraints[keyword];
      if (a == b) continue;
      _add(
        ChangeImpact.potentiallyBreaking,
        'constraint-changed',
        '$keyword changed from ${a ?? '(none)'} to ${b ?? '(none)'}',
        jsonPath: path,
      );
    }

    _compareProperties(old, next, path, direction, depth);

    if (old.items != null && next.items != null) {
      _compareSchema(old.items, next.items, '$path[*]', direction, depth + 1);
    }
    if (old.additionalProperties is Map && next.additionalProperties is Map) {
      _compareSchema(
        old.additionalProperties,
        next.additionalProperties,
        '$path.*',
        direction,
        depth + 1,
      );
    }

    _compareVariants('oneOf', old.oneOf, next.oneOf, path, direction, depth);
    _compareVariants('anyOf', old.anyOf, next.anyOf, path, direction, depth);
  }

  bool _sameTypes(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  bool _isNumeric(Set<String> types) =>
      types.every((type) => type == 'integer' || type == 'number');

  void _compareEnums(_View old, _View next, String path, bool isResponse) {
    final a = old.enumValues;
    final b = next.enumValues;
    if (a == null && b == null) return;
    if (a != null && b == null) {
      _add(
        isResponse
            ? ChangeImpact.potentiallyBreaking
            : ChangeImpact.nonBreaking,
        'enum-removed',
        'value is no longer restricted to an enum',
        jsonPath: path,
      );
      return;
    }
    if (a == null) {
      _add(
        isResponse ? ChangeImpact.nonBreaking : ChangeImpact.breaking,
        'enum-added',
        'value is now restricted to ${_show(b!)}',
        jsonPath: path,
      );
      return;
    }
    final added = [
      for (final v in b!)
        if (!a.contains(v)) v,
    ];
    final removed = [
      for (final v in a)
        if (!b.contains(v)) v,
    ];
    if (added.isNotEmpty) {
      _add(
        isResponse
            ? ChangeImpact.potentiallyBreaking
            : ChangeImpact.nonBreaking,
        'enum-value-added',
        'enum value${added.length == 1 ? '' : 's'} ${_show(added)} added',
        jsonPath: path,
      );
    }
    if (removed.isNotEmpty) {
      _add(
        isResponse ? ChangeImpact.nonBreaking : ChangeImpact.breaking,
        'enum-value-removed',
        'enum value${removed.length == 1 ? '' : 's'} ${_show(removed)} removed',
        jsonPath: path,
      );
    }
  }

  void _compareProperties(
    _View old,
    _View next,
    String path,
    _Direction direction,
    int depth,
  ) {
    final isResponse = direction == _Direction.response;
    bool ignored(Object? schema, OpenApiSpec spec) {
      final view = _view(spec, schema);
      return isResponse ? view.writeOnly : view.readOnly;
    }

    for (final MapEntry(key: name, value: oldProperty)
        in old.properties.entries) {
      if (ignored(oldProperty, before)) continue;
      final propertyPath = JsonPath.property(path, name);
      final newProperty = next.properties[name];
      final wasRequired = old.required.contains(name);
      final isRequired = next.required.contains(name);
      if (!next.properties.containsKey(name)) {
        _add(
          isResponse ? ChangeImpact.breaking : ChangeImpact.potentiallyBreaking,
          'property-removed',
          'property "$name" was removed',
          jsonPath: propertyPath,
        );
        continue;
      }
      if (wasRequired && !isRequired) {
        _add(
          isResponse ? ChangeImpact.breaking : ChangeImpact.nonBreaking,
          'property-optional',
          'property "$name" is no longer required',
          jsonPath: propertyPath,
        );
      } else if (!wasRequired && isRequired) {
        _add(
          isResponse ? ChangeImpact.nonBreaking : ChangeImpact.breaking,
          'property-required',
          'property "$name" is now required',
          jsonPath: propertyPath,
        );
      }
      _compareSchema(
        oldProperty,
        newProperty,
        propertyPath,
        direction,
        depth + 1,
      );
    }
    for (final MapEntry(key: name, value: newProperty)
        in next.properties.entries) {
      if (old.properties.containsKey(name)) continue;
      if (ignored(newProperty, after)) continue;
      final required = next.required.contains(name);
      _add(
        !isResponse && required
            ? ChangeImpact.breaking
            : ChangeImpact.nonBreaking,
        'property-added',
        required
            ? 'required property "$name" was added'
            : 'optional property "$name" was added',
        jsonPath: JsonPath.property(path, name),
      );
    }
  }

  void _compareVariants(
    String keyword,
    List<Object?>? old,
    List<Object?>? next,
    String path,
    _Direction direction,
    int depth,
  ) {
    if (old == null && next == null) return;
    final isResponse = direction == _Direction.response;
    final a = old ?? const [];
    final b = next ?? const [];
    String? refOf(Object? schema) =>
        schema is Map<String, Object?> && schema[r'$ref'] is String
        ? schema[r'$ref']! as String
        : null;
    final byRef = {
      for (final schema in b)
        if (refOf(schema) != null) refOf(schema)!: schema,
    };
    final matched = <Object?>{};
    for (var i = 0; i < a.length; i++) {
      final ref = refOf(a[i]);
      Object? counterpart;
      if (ref != null) {
        counterpart = byRef[ref];
      } else if (i < b.length && refOf(b[i]) == null) {
        counterpart = b[i];
      }
      if (counterpart == null) {
        _add(
          isResponse ? ChangeImpact.nonBreaking : ChangeImpact.breaking,
          'variant-removed',
          '$keyword alternative ${ref == null ? '#$i' : _refName(ref)} '
              'was removed',
          jsonPath: path,
        );
        continue;
      }
      matched.add(counterpart);
      _compareSchema(a[i], counterpart, path, direction, depth + 1);
    }
    for (var i = 0; i < b.length; i++) {
      if (matched.contains(b[i])) continue;
      final ref = refOf(b[i]);
      _add(
        isResponse
            ? ChangeImpact.potentiallyBreaking
            : ChangeImpact.nonBreaking,
        'variant-added',
        '$keyword alternative ${ref == null ? '#$i' : _refName(ref)} was added',
        jsonPath: path,
      );
    }
  }

  _View _view(OpenApiSpec spec, Object? schema) {
    final view = _View();
    _merge(spec, schema, view, <Object>{});
    return view;
  }

  void _merge(OpenApiSpec spec, Object? schema, _View view, Set<Object> seen) {
    if (schema is! Map<String, Object?> || !seen.add(schema)) return;
    final ref = schema[r'$ref'];
    if (ref is String) {
      Object? target;
      try {
        target = spec.resolvePointer(ref);
      } on Object {
        target = null;
      }
      _merge(spec, target, view, seen);
      if (spec.version == OpenApiVersion.v30) return;
    }
    final type = schema['type'];
    if (type is String) {
      if (type == 'null') {
        view.nullable = true;
      } else {
        view.types.add(type);
      }
    } else if (type is List<Object?>) {
      for (final entry in type) {
        if (entry == 'null') {
          view.nullable = true;
        } else {
          view.types.add('$entry');
        }
      }
    }
    if (schema['nullable'] == true) view.nullable = true;
    if (schema['readOnly'] == true) view.readOnly = true;
    if (schema['writeOnly'] == true) view.writeOnly = true;
    final properties = schema['properties'];
    if (properties is Map<String, Object?>) view.properties.addAll(properties);
    final required = schema['required'];
    if (required is List<Object?>) {
      view.required.addAll([for (final name in required) '$name']);
    }
    final enumValues = schema['enum'];
    if (enumValues is List<Object?>) {
      final values = [for (final v in enumValues) ?v];
      if (enumValues.contains(null)) view.nullable = true;
      view.enumValues = values;
    }
    if (schema['format'] is String) view.format = schema['format']! as String;
    if (schema.containsKey('items')) view.items = schema['items'];
    if (schema.containsKey('additionalProperties')) {
      view.additionalProperties = schema['additionalProperties'];
    }
    for (final keyword in _constraintKeywords) {
      if (schema.containsKey(keyword)) {
        view.constraints[keyword] = schema[keyword];
      }
    }
    if (schema['oneOf'] is List<Object?>) {
      view.oneOf = schema['oneOf']! as List<Object?>;
    }
    if (schema['anyOf'] is List<Object?>) {
      view.anyOf = schema['anyOf']! as List<Object?>;
    }
    final allOf = schema['allOf'];
    if (allOf is List<Object?>) {
      for (final member in allOf) {
        _merge(spec, member, view, seen);
      }
    }
  }
}

String _refName(String ref) => OpenApiSpec.schemaNameOf(ref) ?? ref;

String _show(List<Object?> values) {
  final shown = values.take(6).map((v) => v is String ? '"$v"' : '$v');
  return values.length > 6 ? '${shown.join(', ')}, ...' : shown.join(', ');
}
