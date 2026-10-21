import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import 'file_loader_stub.dart'
    if (dart.library.io) 'file_loader_io.dart'
    as file_loader;
import 'operation.dart';
import 'spec_exception.dart';

/// The major/minor version family of an OpenAPI document.
enum OpenApiVersion {
  /// OpenAPI 3.0.x, which uses `nullable` and boolean exclusive bounds.
  v30,

  /// OpenAPI 3.1.x, which uses JSON Schema 2020-12 semantics.
  v31,
}

const _methods = [
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
];

/// A parsed OpenAPI 3.0 or 3.1 document.
///
/// Create one with [OpenApiSpec.fromString], [OpenApiSpec.fromMap] or
/// [OpenApiSpec.fromFile]. Local `$ref`s (`#/components/...`) are resolved
/// lazily through [resolve].
@immutable
final class OpenApiSpec {
  OpenApiSpec._({
    required this.document,
    required this.version,
    required this.openapi,
    required this.operations,
    required this.basePaths,
    required this.title,
    required this.apiVersion,
  });

  /// Parses an already decoded document.
  ///
  /// Throws [OpenApiSpecException] when the document is not OpenAPI 3.x.
  factory OpenApiSpec.fromMap(Map<String, Object?> document) {
    final openapi = document['openapi'];
    if (openapi is! String) {
      if (document['swagger'] != null) {
        throw const OpenApiSpecException(
          'Swagger 2.0 documents are not supported. Convert the document to '
          'OpenAPI 3 first, for example with swagger2openapi.',
        );
      }
      throw const OpenApiSpecException(
        'Missing "openapi" version field; this is not an OpenAPI document.',
      );
    }
    final OpenApiVersion version;
    if (openapi.startsWith('3.0')) {
      version = OpenApiVersion.v30;
    } else if (openapi.startsWith('3.')) {
      version = OpenApiVersion.v31;
    } else {
      throw OpenApiSpecException('Unsupported OpenAPI version "$openapi".');
    }
    final info = _asMap(document['info']);
    final builder = _OperationBuilder(document);
    return OpenApiSpec._(
      document: document,
      version: version,
      openapi: openapi,
      operations: List.unmodifiable(builder.build()),
      basePaths: List.unmodifiable(builder.basePaths),
      title: info?['title'] as String?,
      apiVersion: info?['version']?.toString(),
    );
  }

  /// Parses a JSON or YAML document.
  ///
  /// Throws [OpenApiSpecException] when [source] cannot be parsed.
  factory OpenApiSpec.fromString(String source) {
    final Object? decoded;
    try {
      final trimmed = source.trimLeft();
      decoded = trimmed.startsWith('{')
          ? jsonDecode(trimmed)
          : toPlainJson(loadYaml(source));
    } on FormatException catch (error) {
      throw OpenApiSpecException('Could not parse document: ${error.message}');
    }
    if (decoded is! Map) {
      throw const OpenApiSpecException('The document root must be an object.');
    }
    return OpenApiSpec.fromMap(Map<String, Object?>.from(decoded));
  }

  /// Reads and parses the JSON or YAML document at [path].
  ///
  /// Only available where `dart:io` exists (VM, Flutter mobile and desktop,
  /// tests). On the web, load the text yourself and use [fromString].
  static Future<OpenApiSpec> fromFile(String path) async =>
      OpenApiSpec.fromString(await file_loader.readText(path));

  /// Synchronous variant of [fromFile].
  static OpenApiSpec fromFileSync(String path) =>
      OpenApiSpec.fromString(file_loader.readTextSync(path));

  /// The raw document with YAML converted to plain Dart maps and lists.
  final Map<String, Object?> document;

  /// The OpenAPI version family.
  final OpenApiVersion version;

  /// The exact value of the `openapi` field, for example `3.0.3`.
  final String openapi;

  /// Every operation declared under `paths`.
  final List<ApiOperation> operations;

  /// Base paths derived from `servers` (for example `/v1`). Contains the
  /// empty string when requests may be sent to the root.
  final List<String> basePaths;

  /// `info.title`, if present.
  final String? title;

  /// `info.version`, if present.
  final String? apiVersion;

  /// Finds an operation by `operationId` or by `METHOD /path` reference.
  ApiOperation? operation(String reference) {
    for (final operation in operations) {
      if (operation.matchesReference(reference)) return operation;
    }
    return null;
  }

  /// Like [operation] but throws an [ArgumentError] when not found.
  ApiOperation requireOperation(String reference) =>
      operation(reference) ??
      (throw ArgumentError.value(
        reference,
        'reference',
        'No operation matches. Use an operationId or "METHOD /path"',
      ));

  /// The schema `components.schemas[name]`, if present.
  Object? componentSchema(String name) =>
      _asMap(_asMap(document['components'])?['schemas'])?[name];

  /// `components.securitySchemes`, keyed by scheme name.
  Map<String, Object?> get securitySchemes =>
      _asMap(_asMap(document['components'])?['securitySchemes']) ?? const {};

  /// Returns the node a local JSON pointer such as
  /// `#/components/schemas/User` refers to.
  ///
  /// Throws [OpenApiSpecException] for external or dangling references.
  Object? resolvePointer(String ref) => _resolvePointer(document, ref);

  /// Follows `$ref` chains starting at [node] and returns the target.
  ///
  /// Nodes that are not references are returned unchanged.
  Object? resolve(Object? node) => _resolveNode(document, node);

  /// Decodes the escaped name of a `#/components/schemas/<name>` reference.
  static String? schemaNameOf(String ref) {
    const prefix = '#/components/schemas/';
    if (!ref.startsWith(prefix)) return null;
    return _unescape(ref.substring(prefix.length));
  }

  /// Converts YAML nodes (and any nested maps and lists) to plain
  /// `Map<String, Object?>` and `List<Object?>` values.
  static Object? toPlainJson(Object? node) {
    if (node is Map) {
      return <String, Object?>{
        for (final entry in node.entries)
          entry.key.toString(): toPlainJson(entry.value),
      };
    }
    if (node is List) return [for (final item in node) toPlainJson(item)];
    return node;
  }
}

Map<String, Object?>? _asMap(Object? value) =>
    value is Map<String, Object?> ? value : null;

String _unescape(String token) =>
    Uri.decodeComponent(token).replaceAll('~1', '/').replaceAll('~0', '~');

Object? _resolvePointer(Map<String, Object?> document, String ref) {
  if (!ref.startsWith('#')) {
    throw OpenApiSpecException(
      'External reference "$ref" is not supported. Bundle the document into '
      'a single file first, for example with "redocly bundle".',
    );
  }
  final pointer = ref.substring(1);
  if (pointer.isEmpty) return document;
  Object? current = document;
  for (final raw in pointer.split('/').skip(1)) {
    final token = _unescape(raw);
    if (current is Map<String, Object?> && current.containsKey(token)) {
      current = current[token];
    } else if (current is List<Object?>) {
      final index = int.tryParse(token);
      if (index == null || index < 0 || index >= current.length) {
        throw OpenApiSpecException('Dangling reference "$ref".');
      }
      current = current[index];
    } else {
      throw OpenApiSpecException('Dangling reference "$ref".');
    }
  }
  return current;
}

Object? _resolveNode(Map<String, Object?> document, Object? node) {
  var current = node;
  final seen = <String>{};
  while (current is Map<String, Object?> && current[r'$ref'] is String) {
    final ref = current[r'$ref']! as String;
    if (!seen.add(ref)) {
      throw OpenApiSpecException('Circular reference "$ref".');
    }
    current = _resolvePointer(document, ref);
  }
  return current;
}

final class _OperationBuilder {
  _OperationBuilder(this.document);

  final Map<String, Object?> document;
  final Set<String> _basePaths = {};

  List<String> get basePaths {
    final list = _basePaths.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return list;
  }

  Object? _resolve(Object? node) => _resolveNode(document, node);

  List<ApiOperation> build() {
    _addServers(document['servers']);
    if (_basePaths.isEmpty) _basePaths.add('');
    final paths = _asMap(document['paths']) ?? const {};
    final globalSecurity = _security(document['security']);
    final operations = <ApiOperation>[];
    for (final MapEntry(key: path, value: rawItem) in paths.entries) {
      final item = _asMap(_resolve(rawItem));
      if (item == null) continue;
      _addServers(item['servers']);
      final pathParameters = _parameters(item['parameters']);
      for (final method in _methods) {
        final rawOperation = _asMap(item[method]);
        if (rawOperation == null) continue;
        _addServers(rawOperation['servers']);
        final merged = <String, ApiParameter>{
          for (final p in pathParameters) _parameterKey(p): p,
          for (final p in _parameters(rawOperation['parameters']))
            _parameterKey(p): p,
        };
        operations.add(
          ApiOperation(
            method: method.toUpperCase(),
            path: path,
            operationId: rawOperation['operationId'] as String?,
            summary: rawOperation['summary'] as String?,
            tags: [
              for (final tag in (rawOperation['tags'] as List<Object?>?) ?? [])
                tag.toString(),
            ],
            deprecated: rawOperation['deprecated'] == true,
            parameters: List.unmodifiable(merged.values),
            requestBody: _requestBody(rawOperation['requestBody']),
            responses: _responses(rawOperation['responses']),
            security: rawOperation.containsKey('security')
                ? _security(rawOperation['security'])
                : globalSecurity,
          ),
        );
      }
    }
    return operations;
  }

  void _addServers(Object? servers) {
    if (servers is! List<Object?>) return;
    for (final server in servers) {
      final map = _asMap(server);
      final url = map?['url'];
      if (url is! String) continue;
      final variables = _asMap(map?['variables']) ?? const {};
      final expanded = url.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
        final variable = _asMap(variables[match[1]]);
        return variable?['default']?.toString() ?? '';
      });
      final parsed = Uri.tryParse(expanded);
      var basePath = parsed?.path ?? '';
      while (basePath.endsWith('/')) {
        basePath = basePath.substring(0, basePath.length - 1);
      }
      if (basePath.isNotEmpty && !basePath.startsWith('/')) {
        basePath = '/$basePath';
      }
      _basePaths.add(basePath);
    }
  }

  String _parameterKey(ApiParameter parameter) {
    final name = parameter.location == ParameterLocation.header
        ? parameter.name.toLowerCase()
        : parameter.name;
    return '${parameter.location.name}:$name';
  }

  List<ApiParameter> _parameters(Object? raw) {
    if (raw is! List<Object?>) return const [];
    final result = <ApiParameter>[];
    for (final entry in raw) {
      final map = _asMap(_resolve(entry));
      if (map == null) continue;
      final location = ParameterLocation.tryParse(map['in'] as String?);
      final name = map['name'];
      if (location == null || name is! String) continue;
      Object? schema = map['schema'];
      String? contentMediaType;
      final content = _asMap(map['content']);
      if (schema == null && content != null && content.isNotEmpty) {
        contentMediaType = content.keys.first;
        schema = _asMap(content.values.first)?['schema'];
      }
      result.add(
        ApiParameter(
          name: name,
          location: location,
          required:
              location == ParameterLocation.path || map['required'] == true,
          schema: schema,
          style: map['style'] as String?,
          explode: map['explode'] as bool?,
          deprecated: map['deprecated'] == true,
          allowEmptyValue: map['allowEmptyValue'] == true,
          contentMediaType: contentMediaType,
        ),
      );
    }
    return result;
  }

  Map<String, ApiMediaType> _content(Object? raw) {
    final map = _asMap(raw);
    if (map == null) return const {};
    return Map.unmodifiable({
      for (final MapEntry(:key, :value) in map.entries)
        key: _mediaType(key, _asMap(value) ?? const {}),
    });
  }

  ApiMediaType _mediaType(String key, Map<String, Object?> value) {
    Object? example = value['example'];
    final examples = _asMap(value['examples']);
    if (example == null && examples != null && examples.isNotEmpty) {
      example = _asMap(_resolve(examples.values.first))?['value'];
    }
    return ApiMediaType(
      mediaType: key,
      schema: value['schema'],
      example: example,
    );
  }

  ApiRequestBody? _requestBody(Object? raw) {
    final map = _asMap(_resolve(raw));
    if (map == null) return null;
    return ApiRequestBody(
      required: map['required'] == true,
      content: _content(map['content']),
    );
  }

  Map<String, ApiResponse> _responses(Object? raw) {
    final map = _asMap(raw);
    if (map == null) return const {};
    final result = <String, ApiResponse>{};
    for (final MapEntry(:key, :value) in map.entries) {
      final response = _asMap(_resolve(value));
      if (response == null) continue;
      final headers = <String, ApiHeader>{};
      final rawHeaders = _asMap(response['headers']) ?? const {};
      for (final MapEntry(key: name, value: rawHeader) in rawHeaders.entries) {
        final header = _asMap(_resolve(rawHeader)) ?? const {};
        headers[name.toLowerCase()] = ApiHeader(
          name: name,
          required: header['required'] == true,
          schema: header['schema'],
        );
      }
      result[key] = ApiResponse(
        statusKey: key,
        description: response['description'] as String?,
        content: _content(response['content']),
        headers: Map.unmodifiable(headers),
      );
    }
    return Map.unmodifiable(result);
  }

  List<SecurityRequirement>? _security(Object? raw) {
    if (raw is! List<Object?>) return null;
    return List.unmodifiable([
      for (final entry in raw)
        if (_asMap(entry) case final map?)
          SecurityRequirement(List.unmodifiable(map.keys)),
    ]);
  }
}
