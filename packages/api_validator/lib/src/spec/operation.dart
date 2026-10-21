import 'package:meta/meta.dart';

import 'media_type.dart';

/// Where an [ApiParameter] is sent.
enum ParameterLocation {
  /// A templated segment of the path, such as `{id}` in `/users/{id}`.
  path,

  /// A query string parameter.
  query,

  /// An HTTP request header.
  header,

  /// A cookie sent in the `Cookie` header.
  cookie;

  /// Parses the OpenAPI `in` value.
  static ParameterLocation? tryParse(String? value) => switch (value) {
    'path' => path,
    'query' => query,
    'header' => header,
    'cookie' => cookie,
    _ => null,
  };
}

/// A media type entry of a request body or response `content` map.
@immutable
final class ApiMediaType {
  /// Creates a media type entry.
  const ApiMediaType({required this.mediaType, this.schema, this.example});

  /// The media type key, for example `application/json`.
  final String mediaType;

  /// The raw schema (a `Map` or, in OpenAPI 3.1, a `bool`), if declared.
  final Object? schema;

  /// The first example declared through `example` or `examples`, if any.
  final Object? example;

  /// Whether this media type carries JSON.
  bool get isJson => MediaTypes.isJson(mediaType);
}

/// A parameter of an operation.
@immutable
final class ApiParameter {
  /// Creates a parameter.
  const ApiParameter({
    required this.name,
    required this.location,
    this.required = false,
    this.schema,
    this.style,
    this.explode,
    this.deprecated = false,
    this.allowEmptyValue = false,
    this.contentMediaType,
  });

  /// The parameter name. Header names are compared case-insensitively.
  final String name;

  /// Where the parameter is sent.
  final ParameterLocation location;

  /// Whether the parameter must be present. Path parameters always are.
  final bool required;

  /// The raw schema of the parameter value.
  final Object? schema;

  /// Serialization style (`form`, `simple`, `deepObject`, ...).
  final String? style;

  /// Whether arrays and objects are exploded into separate values.
  final bool? explode;

  /// Whether the parameter is deprecated.
  final bool deprecated;

  /// Whether an empty value is allowed (query parameters only).
  final bool allowEmptyValue;

  /// When the parameter uses `content` instead of `schema`, its media type.
  final String? contentMediaType;

  /// The effective serialization style, applying OpenAPI defaults.
  String get effectiveStyle =>
      style ??
      switch (location) {
        ParameterLocation.query || ParameterLocation.cookie => 'form',
        ParameterLocation.path || ParameterLocation.header => 'simple',
      };

  /// The effective `explode` value, applying OpenAPI defaults.
  bool get effectiveExplode => explode ?? effectiveStyle == 'form';
}

/// The request body of an operation.
@immutable
final class ApiRequestBody {
  /// Creates a request body description.
  const ApiRequestBody({required this.content, this.required = false});

  /// Whether a body must be sent.
  final bool required;

  /// Supported media types keyed by media type string.
  final Map<String, ApiMediaType> content;
}

/// A header declared on a response.
@immutable
final class ApiHeader {
  /// Creates a response header description.
  const ApiHeader({required this.name, this.required = false, this.schema});

  /// The header name.
  final String name;

  /// Whether the header must be present.
  final bool required;

  /// The raw schema of the header value.
  final Object? schema;
}

/// A response declared for one status code (or range) of an operation.
@immutable
final class ApiResponse {
  /// Creates a response description.
  const ApiResponse({
    required this.statusKey,
    this.description,
    this.content = const {},
    this.headers = const {},
  });

  /// The key in the `responses` map: `200`, `4XX` or `default`.
  final String statusKey;

  /// The response description.
  final String? description;

  /// Supported media types keyed by media type string.
  final Map<String, ApiMediaType> content;

  /// Declared headers keyed by lower-case header name.
  final Map<String, ApiHeader> headers;
}

/// One alternative of an operation's security requirements.
///
/// All schemes of a single requirement must be satisfied together.
@immutable
final class SecurityRequirement {
  /// Creates a requirement made of the given scheme names.
  const SecurityRequirement(this.schemes);

  /// Names of the security schemes, as keys of
  /// `components.securitySchemes`.
  final List<String> schemes;

  /// Whether this requirement is the empty requirement `{}`, which makes
  /// authentication optional.
  bool get isAnonymous => schemes.isEmpty;
}

/// A single HTTP operation (a method on a path) declared in the spec.
@immutable
final class ApiOperation {
  /// Creates an operation.
  const ApiOperation({
    required this.method,
    required this.path,
    this.operationId,
    this.summary,
    this.tags = const [],
    this.deprecated = false,
    this.parameters = const [],
    this.requestBody,
    this.responses = const {},
    this.security,
  });

  /// Upper-case HTTP method, for example `GET`.
  final String method;

  /// The path template, for example `/users/{id}`.
  final String path;

  /// The `operationId`, if declared.
  final String? operationId;

  /// The `summary`, if declared.
  final String? summary;

  /// The tags of the operation.
  final List<String> tags;

  /// Whether the operation is deprecated.
  final bool deprecated;

  /// Path-level and operation-level parameters, merged.
  final List<ApiParameter> parameters;

  /// The request body, if declared.
  final ApiRequestBody? requestBody;

  /// Declared responses keyed by status key (`200`, `4XX`, `default`).
  final Map<String, ApiResponse> responses;

  /// Effective security requirements, or `null` when none apply.
  final List<SecurityRequirement>? security;

  /// A stable identifier such as `GET /users/{id}`.
  String get key => '$method $path';

  /// Whether [reference] names this operation, either by [key]
  /// (case-insensitive method) or by [operationId].
  bool matchesReference(String reference) {
    final trimmed = reference.trim();
    if (operationId != null && trimmed == operationId) return true;
    final space = trimmed.indexOf(' ');
    if (space < 0) return false;
    return trimmed.substring(0, space).toUpperCase() == method &&
        trimmed.substring(space + 1).trim() == path;
  }

  /// The response key that covers [statusCode]: the exact code, then the
  /// range (`4XX`), then `default`.
  String? responseKeyFor(int statusCode) {
    final exact = '$statusCode';
    if (responses.containsKey(exact)) return exact;
    final range = '${statusCode ~/ 100}XX';
    for (final key in responses.keys) {
      if (key.toUpperCase() == range) return key;
    }
    if (responses.containsKey('default')) return 'default';
    return null;
  }

  /// The response that covers [statusCode], see [responseKeyFor].
  ApiResponse? responseFor(int statusCode) {
    final key = responseKeyFor(statusCode);
    return key == null ? null : responses[key];
  }

  @override
  String toString() => key;
}
