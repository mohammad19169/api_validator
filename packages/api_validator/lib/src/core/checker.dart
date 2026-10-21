import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../coverage/coverage.dart';
import '../routing/operation_matcher.dart';
import '../schema/schema_error.dart';
import '../schema/schema_validator.dart';
import '../spec/media_type.dart';
import '../spec/openapi_spec.dart';
import '../spec/operation.dart';
import 'exchange.dart';
import 'options.dart';
import 'violation.dart';

/// The outcome of checking one [Exchange].
@immutable
final class ValidationResult {
  /// Creates a result.
  ValidationResult({
    required this.exchange,
    required List<Violation> violations,
    this.operation,
    this.responseKey,
    this.skipped = false,
    DateTime? timestamp,
  }) : violations = List.unmodifiable(violations),
       timestamp = timestamp ?? DateTime.now();

  /// The checked exchange.
  final Exchange exchange;

  /// The operation the request was routed to, if any.
  final ApiOperation? operation;

  /// The response key (`200`, `4XX`, `default`) the response matched.
  final String? responseKey;

  /// Everything found, errors and warnings.
  final List<Violation> violations;

  /// Whether the exchange was skipped (ignored path or operation, or the
  /// checker was disabled).
  final bool skipped;

  /// When the exchange was checked.
  final DateTime timestamp;

  /// Violations with [Severity.error].
  List<Violation> get errors => [
    for (final violation in violations)
      if (violation.isError) violation,
  ];

  /// Violations with [Severity.warning].
  List<Violation> get warnings => [
    for (final violation in violations)
      if (!violation.isError) violation,
  ];

  /// Whether no error was found. Warnings are allowed.
  bool get isValid => !violations.any((violation) => violation.isError);

  /// A short label such as `GET /users/{id} -> 200`.
  String get label {
    final request = exchange.request;
    final target = operation?.key ?? '${request.method} ${request.uri.path}';
    final status = exchange.response?.statusCode;
    return status == null ? target : '$target -> $status';
  }

  @override
  String toString() {
    if (violations.isEmpty) return '✓ $label';
    return [
      '${isValid ? '!' : '✗'} $label',
      for (final violation in violations)
        '    ${violation.isError ? 'error' : 'warning'}: $violation',
    ].join('\n');
  }
}

/// Thrown by [ApiValidator.verify] when errors were recorded.
final class ApiValidationException implements Exception {
  /// Creates the exception for [violations].
  ApiValidationException(List<Violation> violations)
    : violations = List.unmodifiable(violations);

  /// The errors that were found.
  final List<Violation> violations;

  @override
  String toString() {
    final count = violations.length;
    return [
      'ApiValidationException: $count validation error${count == 1 ? '' : 's'}',
      for (final violation in violations) '  - $violation',
    ].join('\n');
  }
}

/// Checks HTTP exchanges against an [OpenApiSpec] and records the results.
///
/// Usually you do not call [check] yourself: install an adapter such as the
/// dio interceptor from `api_validator_dio` or the client wrapper from
/// `api_validator_http`, and inspect [violations] or [coverage] after
/// your code ran.
///
/// ```dart
/// final checker = ApiValidator(OpenApiSpec.fromString(yaml));
/// final result = checker.check(Exchange(
///   request: ExchangeRequest(method: 'GET', uri: Uri.parse('/users/1')),
///   response: ExchangeResponse(statusCode: 200, body: {'id': 1}),
/// ));
/// print(result);
/// ```
final class ApiValidator {
  /// Creates a checker for [spec].
  ApiValidator(this.spec, {this.options = const ValidatorOptions()})
    : _matcher = OperationMatcher(spec),
      _validator = SchemaValidator(
        spec,
        validateFormats: options.validateFormats,
        customFormats: options.customFormats,
      ),
      _coverage = CoverageTracker(spec);

  /// Loads the spec at [path] and creates a checker for it.
  ///
  /// Needs `dart:io`; see [OpenApiSpec.fromFile].
  static Future<ApiValidator> fromFile(
    String path, {
    ValidatorOptions options = const ValidatorOptions(),
  }) async => ApiValidator(await OpenApiSpec.fromFile(path), options: options);

  /// The spec exchanges are checked against.
  final OpenApiSpec spec;

  /// The active options.
  final ValidatorOptions options;

  /// When `false`, [check] does nothing and records nothing.
  ///
  /// Use it to switch checks off in release builds:
  /// `checker.enabled = kDebugMode;`.
  bool enabled = true;

  final OperationMatcher _matcher;
  final SchemaValidator _validator;
  final CoverageTracker _coverage;
  final ListQueue<ValidationResult> _results = ListQueue();
  final StreamController<ValidationResult> _controller =
      StreamController.broadcast();

  /// Recorded results, oldest first.
  List<ValidationResult> get results => List.unmodifiable(_results);

  /// Every violation in [results].
  List<Violation> get violations => [
    for (final result in _results) ...result.violations,
  ];

  /// Every violation with [Severity.error] in [results].
  List<Violation> get errors => [
    for (final result in _results) ...result.errors,
  ];

  /// Whether no error has been recorded.
  bool get isValid => _results.every((result) => result.isValid);

  /// Coverage of the spec so far. Survives [reset] unless asked otherwise.
  CoverageReport get coverage => _coverage.report;

  /// Emits every result as it is recorded.
  Stream<ValidationResult> get onResult => _controller.stream;

  /// Routes a request to the operation it targets, without validating it.
  RouteResult route(String method, Uri uri) => _matcher.match(method, uri);

  /// Clears recorded results. Coverage is kept unless [coverage] is `true`.
  void reset({bool coverage = false}) {
    _results.clear();
    if (coverage) _coverage.reset();
  }

  /// Throws a [ApiValidationException] when errors were recorded since the last
  /// [reset], then resets when [resetAfter] is `true`.
  void verify({bool resetAfter = true}) {
    final found = errors;
    if (resetAfter) reset();
    if (found.isNotEmpty) throw ApiValidationException(found);
  }

  /// Closes [onResult]. The checker must not be used afterwards.
  Future<void> dispose() => _controller.close();

  /// Checks [exchange], records the result and returns it.
  ValidationResult check(Exchange exchange) {
    final result = evaluate(exchange);
    if (result.skipped && !enabled) return result;
    _record(result);
    return result;
  }

  /// Checks [exchange] without recording anything.
  ValidationResult evaluate(Exchange exchange) {
    if (!enabled) {
      return ValidationResult(
        exchange: exchange,
        violations: const [],
        skipped: true,
      );
    }
    final request = exchange.request;
    final path = request.uri.path.isEmpty ? '/' : request.uri.path;
    if (options.ignorePaths.any((pattern) => _matchesWhole(pattern, path))) {
      return ValidationResult(
        exchange: exchange,
        violations: const [],
        skipped: true,
      );
    }
    final label = '${request.method} ${request.uri}';
    final route = _matcher.match(request.method, request.uri);
    switch (route) {
      case RouteNotFound():
        return _unmatched(
          exchange,
          (severity) => UnknownOperation(
            severity: severity,
            method: request.method,
            path: path,
            request: label,
          ),
        );
      case RouteMethodNotAllowed(path: final template, :final allowedMethods):
        return _unmatched(
          exchange,
          (severity) => MethodNotAllowed(
            severity: severity,
            method: request.method,
            path: template,
            allowedMethods: allowedMethods,
            request: label,
          ),
        );
      case RouteMatched(:final operation, :final pathParameters):
        if (options.ignoreOperations.any(operation.matchesReference)) {
          return ValidationResult(
            exchange: exchange,
            violations: const [],
            operation: operation,
            skipped: true,
          );
        }
        final run = _ExchangeRun(
          this,
          operation,
          exchange,
          pathParameters,
          label,
        );
        run.validate();
        return ValidationResult(
          exchange: exchange,
          violations: run.violations,
          operation: operation,
          responseKey: run.responseKey,
        );
    }
  }

  ValidationResult _unmatched(
    Exchange exchange,
    Violation Function(Severity severity) create,
  ) {
    final severity = switch (options.unmatchedRequests) {
      UnmatchedPolicy.error => Severity.error,
      UnmatchedPolicy.warning => Severity.warning,
      UnmatchedPolicy.ignore => null,
    };
    return ValidationResult(
      exchange: exchange,
      violations: severity == null ? const [] : [create(severity)],
      skipped: severity == null,
    );
  }

  void _record(ValidationResult result) {
    final operation = result.operation;
    if (operation != null && !result.skipped) {
      _coverage.record(operation, responseKey: result.responseKey);
    }
    if (result.skipped) return;
    _results.add(result);
    final limit = options.maxRecordedResults;
    if (limit != null) {
      while (_results.length > limit) {
        _results.removeFirst();
      }
    }
    for (final violation in result.violations) {
      options.onViolation?.call(violation);
      if (options.log) {
        developer.log(
          violation.toString(),
          name: 'api_validator',
          level: violation.isError ? 1000 : 900,
        );
      }
    }
    if (!_controller.isClosed) _controller.add(result);
  }
}

bool _matchesWhole(Pattern pattern, String path) {
  if (pattern is String) return pattern == path;
  return pattern.allMatches(path).isNotEmpty;
}

const _ignoredHeaderParameters = {'accept', 'content-type', 'authorization'};

final class _Absent {
  const _Absent();
}

const _absent = _Absent();

final class _ExchangeRun {
  _ExchangeRun(
    this.checker,
    this.operation,
    this.exchange,
    this.pathParameters,
    this.label,
  );

  final ApiValidator checker;
  final ApiOperation operation;
  final Exchange exchange;
  final Map<String, String> pathParameters;
  final String label;
  final List<Violation> violations = [];
  String? responseKey;

  ValidatorOptions get options => checker.options;
  OpenApiSpec get spec => checker.spec;
  SchemaValidator get validator => checker._validator;
  ExchangeRequest get request => exchange.request;

  void validate() {
    if (options.reportDeprecated && operation.deprecated) {
      _add(
        DeprecatedOperation(
          severity: Severity.warning,
          operation: operation.key,
          request: label,
        ),
      );
    }
    if (options.validateRequests) {
      _checkParameters();
      if (options.checkSecurity) _checkSecurity();
      if (request.bodyCaptured) _checkRequestBody();
    }
    final response = exchange.response;
    if (response != null) {
      responseKey = operation.responseKeyFor(response.statusCode);
      if (options.validateResponses) _checkResponse(response);
    }
  }

  void _add(Violation violation) => violations.add(violation);

  // ---------------------------------------------------------------------------
  // Parameters

  void _checkParameters() {
    final query = request.uri.queryParametersAll;
    final cookies = _cookies(request.header('cookie'));
    for (final parameter in operation.parameters) {
      if (parameter.location == ParameterLocation.header &&
          _ignoredHeaderParameters.contains(parameter.name.toLowerCase())) {
        continue;
      }
      final location = switch (parameter.location) {
        ParameterLocation.path => ViolationLocation.requestPath,
        ParameterLocation.query => ViolationLocation.requestQuery,
        ParameterLocation.header => ViolationLocation.requestHeader,
        ParameterLocation.cookie => ViolationLocation.requestCookie,
      };
      final value = _parameterValue(parameter, query, cookies);
      if (value is _Absent) {
        if (parameter.required) {
          _add(
            MissingParameter(
              severity: Severity.error,
              location: location,
              name: parameter.name,
              operation: operation.key,
              request: label,
            ),
          );
        }
        continue;
      }
      if (value == '' && parameter.allowEmptyValue) continue;
      final errors = validator.validate(
        parameter.schema,
        value,
        path: JsonPath.property(JsonPath.root, parameter.name),
      );
      for (final error in errors.where((e) => !e.isUndeclaredProperty)) {
        _add(
          InvalidParameter(
            severity: Severity.error,
            location: location,
            name: parameter.name,
            error: error,
            operation: operation.key,
            request: label,
          ),
        );
      }
    }
  }

  Object? _parameterValue(
    ApiParameter parameter,
    Map<String, List<String>> query,
    Map<String, String> cookies,
  ) {
    final schema = _resolvedSchema(parameter.schema);
    final type = _primaryType(schema);
    switch (parameter.location) {
      case ParameterLocation.path:
        final raw = pathParameters[parameter.name];
        if (raw == null) return _absent;
        return _deserialize(parameter, schema, type, [raw]);
      case ParameterLocation.header:
        final raw = request.header(parameter.name);
        if (raw == null) return _absent;
        return _deserialize(parameter, schema, type, [raw]);
      case ParameterLocation.cookie:
        final raw = cookies[parameter.name];
        if (raw == null) return _absent;
        return _deserialize(parameter, schema, type, [raw]);
      case ParameterLocation.query:
        if (type == 'object' && parameter.effectiveStyle == 'deepObject') {
          final prefix = '${parameter.name}[';
          final entries = <String, Object?>{};
          for (final MapEntry(:key, :value) in query.entries) {
            if (key.startsWith(prefix) && key.endsWith(']')) {
              final property = key.substring(prefix.length, key.length - 1);
              entries[property] = _coerce(
                value.first,
                _propertySchema(schema, property),
              );
            }
          }
          return entries.isEmpty ? _absent : entries;
        }
        if (type == 'object' && parameter.effectiveExplode) {
          final properties = _properties(schema);
          final entries = <String, Object?>{
            for (final MapEntry(:key, :value) in query.entries)
              if (properties.containsKey(key))
                key: _coerce(value.first, properties[key]),
          };
          return entries.isEmpty ? _absent : entries;
        }
        final values = query[parameter.name];
        if (values == null) return _absent;
        return _deserialize(parameter, schema, type, values);
    }
  }

  Object? _deserialize(
    ApiParameter parameter,
    Object? schema,
    String? type,
    List<String> values,
  ) {
    if (parameter.contentMediaType != null &&
        MediaTypes.isJson(parameter.contentMediaType)) {
      try {
        return jsonDecode(values.first);
      } on FormatException {
        return values.first;
      }
    }
    if (type == 'array') {
      final items = schema is Map<String, Object?> ? schema['items'] : null;
      final List<String> parts;
      if (parameter.location == ParameterLocation.query &&
          parameter.effectiveExplode &&
          parameter.effectiveStyle == 'form') {
        parts = values;
      } else {
        final delimiter = switch (parameter.effectiveStyle) {
          'spaceDelimited' => ' ',
          'pipeDelimited' => '|',
          _ => ',',
        };
        parts = [
          for (final value in values)
            if (value.isNotEmpty) ...value.split(delimiter),
        ];
      }
      return [for (final part in parts) _coerce(part, items)];
    }
    if (type == 'object') {
      final pairs = <String, Object?>{};
      final raw = values.first;
      if (parameter.effectiveExplode) {
        for (final pair in raw.split(',')) {
          final index = pair.indexOf('=');
          if (index <= 0) continue;
          final key = pair.substring(0, index);
          pairs[key] = _coerce(
            pair.substring(index + 1),
            _propertySchema(schema, key),
          );
        }
      } else {
        final parts = raw.split(',');
        for (var i = 0; i + 1 < parts.length; i += 2) {
          pairs[parts[i]] = _coerce(
            parts[i + 1],
            _propertySchema(schema, parts[i]),
          );
        }
      }
      return pairs;
    }
    return _coerce(values.first, schema);
  }

  Object? _coerce(String raw, Object? schema) {
    final resolved = _resolvedSchema(schema);
    final type = _primaryType(resolved);
    switch (type) {
      case 'integer':
        return int.tryParse(raw) ?? num.tryParse(raw) ?? raw;
      case 'number':
        return num.tryParse(raw) ?? raw;
      case 'boolean':
        return switch (raw) {
          'true' => true,
          'false' => false,
          _ => raw,
        };
      case 'null':
        return raw.isEmpty || raw == 'null' ? null : raw;
      case null:
        if (resolved is Map<String, Object?> &&
            (resolved.containsKey('oneOf') || resolved.containsKey('anyOf'))) {
          final candidates = <Object?>[
            raw,
            int.tryParse(raw),
            num.tryParse(raw),
            if (raw == 'true') true,
            if (raw == 'false') false,
          ];
          for (final candidate in candidates) {
            if (candidate != null && validator.isValid(resolved, candidate)) {
              return candidate;
            }
          }
        }
        return raw;
      default:
        return raw;
    }
  }

  Object? _resolvedSchema(Object? schema) {
    try {
      return spec.resolve(schema);
    } on Object {
      return schema;
    }
  }

  String? _primaryType(Object? schema) {
    if (schema is! Map<String, Object?>) return null;
    final type = schema['type'];
    if (type is String) return type;
    if (type is List<Object?>) {
      for (final entry in type) {
        if (entry != 'null') return '$entry';
      }
      return 'null';
    }
    final allOf = schema['allOf'];
    if (allOf is List<Object?>) {
      for (final member in allOf) {
        final memberType = _primaryType(_resolvedSchema(member));
        if (memberType != null) return memberType;
      }
    }
    return null;
  }

  Map<String, Object?> _properties(Object? schema) {
    final result = <String, Object?>{};
    final resolved = _resolvedSchema(schema);
    if (resolved is! Map<String, Object?>) return result;
    final properties = resolved['properties'];
    if (properties is Map<String, Object?>) result.addAll(properties);
    final allOf = resolved['allOf'];
    if (allOf is List<Object?>) {
      for (final member in allOf) {
        result.addAll(_properties(member));
      }
    }
    return result;
  }

  Object? _propertySchema(Object? schema, String name) =>
      _properties(schema)[name];

  Map<String, String> _cookies(String? header) {
    if (header == null) return const {};
    final result = <String, String>{};
    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      result[part.substring(0, index).trim()] = part
          .substring(index + 1)
          .trim();
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Security

  void _checkSecurity() {
    final requirements = operation.security;
    if (requirements == null || requirements.isEmpty) return;
    final schemes = spec.securitySchemes;
    final query = request.uri.queryParameters;
    final cookies = _cookies(request.header('cookie'));
    bool satisfied(String name) {
      final scheme = _resolvedSchema(schemes[name]);
      if (scheme is! Map<String, Object?>) return true;
      switch (scheme['type']) {
        case 'apiKey':
          final keyName = '${scheme['name']}';
          return switch (scheme['in']) {
            'header' => request.header(keyName) != null,
            'query' => query.containsKey(keyName),
            'cookie' => cookies.containsKey(keyName),
            _ => true,
          };
        case 'http':
          final authorization = request.header('authorization');
          if (authorization == null) return false;
          final expected = scheme['scheme'];
          if (expected is! String) return true;
          return authorization.toLowerCase().startsWith(
            '${expected.toLowerCase()} ',
          );
        case 'oauth2' || 'openIdConnect':
          return request.header('authorization') != null;
        default:
          return true;
      }
    }

    for (final requirement in requirements) {
      if (requirement.isAnonymous || requirement.schemes.every(satisfied)) {
        return;
      }
    }
    _add(
      MissingCredentials(
        severity: Severity.warning,
        requirements: [
          for (final requirement in requirements) requirement.schemes,
        ],
        operation: operation.key,
        request: label,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bodies

  void _checkRequestBody() {
    final body = request.body;
    final hasBody = !_isEmptyBody(body);
    final declared = operation.requestBody;
    if (declared == null) {
      if (hasBody) {
        _add(
          UnsupportedContentType(
            severity: options.strictSeverity,
            location: ViolationLocation.requestBody,
            contentType: request.contentType,
            declared: const [],
            operation: operation.key,
            request: label,
          ),
        );
      }
      return;
    }
    if (!hasBody) {
      if (declared.required) {
        _add(
          MissingBody(
            severity: Severity.error,
            operation: operation.key,
            request: label,
          ),
        );
      }
      return;
    }
    _checkBody(
      content: declared.content,
      contentType: request.contentType,
      body: body,
      location: ViolationLocation.requestBody,
      direction: SchemaDirection.request,
    );
  }

  void _checkResponse(ExchangeResponse response) {
    final key = responseKey;
    if (operation.responses.isEmpty) return;
    if (key == null) {
      _add(
        UndeclaredStatus(
          severity: options.strictSeverity,
          statusCode: response.statusCode,
          declaredStatuses: operation.responses.keys.toList(),
          operation: operation.key,
          request: label,
        ),
      );
      return;
    }
    final declared = operation.responses[key]!;
    for (final header in declared.headers.values) {
      if (header.name.toLowerCase() == 'content-type') continue;
      final value = response.header(header.name);
      if (value == null) {
        if (header.required) {
          _add(
            MissingParameter(
              severity: Severity.error,
              location: ViolationLocation.responseHeader,
              name: header.name,
              operation: operation.key,
              request: label,
            ),
          );
        }
        continue;
      }
      final errors = validator.validate(
        header.schema,
        _coerce(value, header.schema),
        path: JsonPath.property(JsonPath.root, header.name),
      );
      for (final error in errors.where((e) => !e.isUndeclaredProperty)) {
        _add(
          InvalidParameter(
            severity: Severity.error,
            location: ViolationLocation.responseHeader,
            name: header.name,
            error: error,
            operation: operation.key,
            request: label,
          ),
        );
      }
    }

    if (!response.bodyCaptured) return;
    final body = response.body;
    final hasBody = !_isEmptyBody(body);
    if (declared.content.isEmpty) {
      if (hasBody && exchange.request.method != 'HEAD') {
        _add(
          UnsupportedContentType(
            severity: options.strictSeverity,
            location: ViolationLocation.responseBody,
            contentType: response.contentType,
            declared: const [],
            operation: operation.key,
            request: label,
          ),
        );
      }
      return;
    }
    if (!hasBody) {
      if (exchange.request.method == 'HEAD' || response.statusCode == 204) {
        return;
      }
      _add(
        SchemaMismatch(
          severity: options.strictSeverity,
          location: ViolationLocation.responseBody,
          error: const SchemaError(
            path: JsonPath.root,
            keyword: 'content',
            message: 'the response body is empty but the spec declares content',
          ),
          operation: operation.key,
          request: label,
        ),
      );
      return;
    }
    _checkBody(
      content: declared.content,
      contentType: response.contentType,
      body: body,
      location: ViolationLocation.responseBody,
      direction: SchemaDirection.response,
    );
  }

  void _checkBody({
    required Map<String, ApiMediaType> content,
    required String? contentType,
    required Object? body,
    required ViolationLocation location,
    required SchemaDirection direction,
  }) {
    final key = MediaTypes.select(content.keys, contentType);
    if (key == null) {
      _add(
        UnsupportedContentType(
          severity: Severity.error,
          location: location,
          contentType: contentType,
          declared: content.keys.toList(),
          operation: operation.key,
          request: label,
        ),
      );
      return;
    }
    final media = content[key]!;
    if (media.schema == null) return;
    final essence = MediaTypes.essence(key);
    final Object? value;
    if (media.isJson ||
        ((essence == '*/*' || essence.endsWith('/*')) &&
            MediaTypes.isJson(contentType))) {
      final decoded = _decodeJson(body);
      if (decoded case _JsonFailure(:final message)) {
        _add(
          InvalidJson(
            severity: Severity.error,
            location: location,
            details: message,
            operation: operation.key,
            request: label,
          ),
        );
        return;
      }
      value = decoded;
    } else if (essence == 'application/x-www-form-urlencoded') {
      final text = body is String ? body : _textOf(body);
      if (text == null && body is! Map) return;
      final fields = body is Map
          ? {for (final e in body.entries) '${e.key}': '${e.value}'}
          : Uri.splitQueryString(text!);
      final properties = _properties(media.schema);
      value = {
        for (final MapEntry(key: name, value: raw) in fields.entries)
          name: _coerce(raw, properties[name]),
      };
    } else if (essence.startsWith('text/')) {
      final text = body is String ? body : _textOf(body);
      if (text == null) return;
      value = text;
    } else {
      return;
    }
    final errors = validator.validate(
      media.schema,
      value,
      direction: direction,
    );
    for (final error in errors) {
      if (error.isUndeclaredProperty) {
        _add(
          UndeclaredProperty(
            severity: options.strictSeverity,
            location: location,
            error: error,
            operation: operation.key,
            request: label,
          ),
        );
      } else {
        final relaxed =
            error.keyword == 'readOnly' || error.keyword == 'writeOnly';
        _add(
          SchemaMismatch(
            severity: relaxed ? options.strictSeverity : Severity.error,
            location: location,
            error: error,
            operation: operation.key,
            request: label,
          ),
        );
      }
    }
  }
}

final class _JsonFailure {
  const _JsonFailure(this.message);

  final String message;
}

Object? _decodeJson(Object? body) {
  final text = body is String ? body : _textOf(body);
  if (text == null) return body;
  try {
    return jsonDecode(text);
  } on FormatException catch (error) {
    return _JsonFailure(error.message);
  }
}

String? _textOf(Object? body) {
  if (body is String) return body;
  if (body is Uint8List) return utf8.decode(body, allowMalformed: true);
  return null;
}

bool _isEmptyBody(Object? body) {
  if (body == null) return true;
  if (body is String) return body.trim().isEmpty;
  if (body is Uint8List) return body.isEmpty;
  return false;
}
