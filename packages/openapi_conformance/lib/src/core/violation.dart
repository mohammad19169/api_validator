import 'package:meta/meta.dart';

import '../schema/schema_error.dart';

/// How serious a [Violation] is.
enum Severity {
  /// The exchange does not conform to the spec. Fails tests.
  error,

  /// Suspicious but tolerated, for example an undeclared property in lenient
  /// mode. Reported, but does not fail tests.
  warning,
}

/// Which part of an exchange a [Violation] concerns.
enum ViolationLocation {
  /// Routing the request to an operation.
  route('route'),

  /// A path parameter.
  requestPath('request.path'),

  /// A query parameter.
  requestQuery('request.query'),

  /// A request header.
  requestHeader('request.header'),

  /// A cookie.
  requestCookie('request.cookie'),

  /// Credentials required by the operation's security requirements.
  requestSecurity('request.security'),

  /// The request body.
  requestBody('request.body'),

  /// The response status code.
  responseStatus('response.status'),

  /// A response header.
  responseHeader('response.header'),

  /// The response body.
  responseBody('response.body');

  const ViolationLocation(this.label);

  /// Short label such as `response.body`, used in messages.
  final String label;

  /// Whether this location belongs to the request.
  bool get isRequest => label.startsWith('request');

  /// Whether this location belongs to the response.
  bool get isResponse => label.startsWith('response');
}

/// A way in which an exchange does not match the spec.
///
/// Use pattern matching on the subclasses to handle specific kinds:
///
/// ```dart
/// for (final violation in result.violations) {
///   switch (violation) {
///     case SchemaMismatch(:final error):
///       print('Bad field ${error.path}');
///     case UndeclaredStatus(:final statusCode):
///       print('Unexpected status $statusCode');
///     default:
///       print(violation);
///   }
/// }
/// ```
@immutable
sealed class Violation {
  const Violation({
    required this.severity,
    required this.location,
    required this.message,
    this.operation,
    this.request,
  });

  /// Whether this violation fails tests.
  final Severity severity;

  /// The part of the exchange concerned.
  final ViolationLocation location;

  /// Human readable description.
  final String message;

  /// The matched operation key (`GET /users/{id}`), when routing succeeded.
  final String? operation;

  /// A short description of the request (`GET https://...`).
  final String? request;

  /// The JSON path of the offending value, for body violations.
  String? get jsonPath => null;

  /// Whether this violation has [Severity.error].
  bool get isError => severity == Severity.error;

  /// Machine readable kind, for example `schema-mismatch`.
  String get kind;

  /// A copy of this violation with [severity] and context replaced.
  Violation withContext({
    Severity? severity,
    String? operation,
    String? request,
  });

  /// Serializes this violation for JSON reports.
  Map<String, Object?> toJson() => {
    'kind': kind,
    'severity': severity.name,
    'location': location.label,
    'message': message,
    if (jsonPath != null) 'jsonPath': jsonPath,
    if (operation != null) 'operation': operation,
    if (request != null) 'request': request,
  };

  @override
  String toString() {
    final buffer = StringBuffer('[${location.label}] ');
    if (jsonPath != null) buffer.write('$jsonPath: ');
    buffer.write(message);
    final context = operation ?? request;
    if (context != null) buffer.write(' ($context)');
    return buffer.toString();
  }
}

/// No operation in the spec matches the request path.
final class UnknownOperation extends Violation {
  /// Creates the violation.
  const UnknownOperation({
    required super.severity,
    required this.method,
    required this.path,
    super.request,
  }) : super(
         location: ViolationLocation.route,
         message: 'no operation in the spec matches $method $path',
       );

  /// The request method.
  final String method;

  /// The request path after stripping the server base path.
  final String path;

  @override
  String get kind => 'unknown-operation';

  @override
  UnknownOperation withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => UnknownOperation(
    severity: severity ?? this.severity,
    method: method,
    path: path,
    request: request ?? this.request,
  );
}

/// The path exists in the spec but not for the request method.
final class MethodNotAllowed extends Violation {
  /// Creates the violation.
  MethodNotAllowed({
    required super.severity,
    required this.method,
    required this.path,
    required this.allowedMethods,
    super.request,
  }) : super(
         location: ViolationLocation.route,
         message:
             '$method is not declared for $path; declared methods: '
             '${allowedMethods.join(', ')}',
       );

  /// The request method.
  final String method;

  /// The matched path template.
  final String path;

  /// Methods declared for [path].
  final List<String> allowedMethods;

  @override
  String get kind => 'method-not-allowed';

  @override
  MethodNotAllowed withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => MethodNotAllowed(
    severity: severity ?? this.severity,
    method: method,
    path: path,
    allowedMethods: allowedMethods,
    request: request ?? this.request,
  );
}

/// The operation does not declare the response status code.
final class UndeclaredStatus extends Violation {
  /// Creates the violation.
  UndeclaredStatus({
    required super.severity,
    required this.statusCode,
    required this.declaredStatuses,
    super.operation,
    super.request,
  }) : super(
         location: ViolationLocation.responseStatus,
         message:
             'status $statusCode is not declared; declared: '
             '${declaredStatuses.join(', ')}',
       );

  /// The status code received.
  final int statusCode;

  /// Response keys declared by the operation.
  final List<String> declaredStatuses;

  @override
  String get kind => 'undeclared-status';

  @override
  UndeclaredStatus withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => UndeclaredStatus(
    severity: severity ?? this.severity,
    statusCode: statusCode,
    declaredStatuses: declaredStatuses,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// A required parameter or header is missing.
final class MissingParameter extends Violation {
  /// Creates the violation.
  MissingParameter({
    required super.severity,
    required super.location,
    required this.name,
    super.operation,
    super.request,
  }) : super(message: 'required ${_noun(location)} "$name" is missing');

  /// The parameter or header name.
  final String name;

  @override
  String get kind => 'missing-parameter';

  @override
  MissingParameter withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => MissingParameter(
    severity: severity ?? this.severity,
    location: location,
    name: name,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// A parameter or header value does not match its schema.
final class InvalidParameter extends Violation {
  /// Creates the violation.
  InvalidParameter({
    required super.severity,
    required super.location,
    required this.name,
    required this.error,
    super.operation,
    super.request,
  }) : super(message: '${_noun(location)} "$name": ${error.message}');

  /// The parameter or header name.
  final String name;

  /// Why the value is invalid.
  final SchemaError error;

  @override
  String get kind => 'invalid-parameter';

  @override
  InvalidParameter withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => InvalidParameter(
    severity: severity ?? this.severity,
    location: location,
    name: name,
    error: error,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// None of the operation's security requirements is satisfied.
final class MissingCredentials extends Violation {
  /// Creates the violation.
  MissingCredentials({
    required super.severity,
    required this.requirements,
    super.operation,
    super.request,
  }) : super(
         location: ViolationLocation.requestSecurity,
         message:
             'no credentials for any security requirement: '
             '${requirements.map((r) => r.join(' + ')).join(' | ')}',
       );

  /// The unmet requirements, each a list of scheme names.
  final List<List<String>> requirements;

  @override
  String get kind => 'missing-credentials';

  @override
  MissingCredentials withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => MissingCredentials(
    severity: severity ?? this.severity,
    requirements: requirements,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// A required request body is missing.
final class MissingBody extends Violation {
  /// Creates the violation.
  const MissingBody({required super.severity, super.operation, super.request})
    : super(
        location: ViolationLocation.requestBody,
        message: 'the request body is required but was not sent',
      );

  @override
  String get kind => 'missing-body';

  @override
  MissingBody withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => MissingBody(
    severity: severity ?? this.severity,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// The body's content type is not declared for the request or response.
final class UnsupportedContentType extends Violation {
  /// Creates the violation.
  UnsupportedContentType({
    required super.severity,
    required super.location,
    required this.contentType,
    required this.declared,
    super.operation,
    super.request,
  }) : super(
         message: declared.isEmpty
             ? 'a body was sent but none is declared'
             : 'content type "${contentType ?? '(none)'}" is not declared; '
                   'declared: ${declared.join(', ')}',
       );

  /// The content type received, if any.
  final String? contentType;

  /// Declared media types.
  final List<String> declared;

  @override
  String get kind => 'unsupported-content-type';

  @override
  UnsupportedContentType withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => UnsupportedContentType(
    severity: severity ?? this.severity,
    location: location,
    contentType: contentType,
    declared: declared,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// The body claims to be JSON but cannot be parsed.
final class InvalidJson extends Violation {
  /// Creates the violation.
  InvalidJson({
    required super.severity,
    required super.location,
    required this.details,
    super.operation,
    super.request,
  }) : super(message: 'the body is not valid JSON: $details');

  /// The parser error.
  final String details;

  @override
  String get kind => 'invalid-json';

  @override
  InvalidJson withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => InvalidJson(
    severity: severity ?? this.severity,
    location: location,
    details: details,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// A body value does not match its schema.
final class SchemaMismatch extends Violation {
  /// Creates the violation.
  SchemaMismatch({
    required super.severity,
    required super.location,
    required this.error,
    super.operation,
    super.request,
  }) : super(message: error.message);

  /// The schema error.
  final SchemaError error;

  @override
  String? get jsonPath => error.path;

  @override
  String get kind => 'schema-mismatch';

  @override
  SchemaMismatch withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => SchemaMismatch(
    severity: severity ?? this.severity,
    location: location,
    error: error,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// A body contains a property the schema does not declare.
///
/// An error in strict mode and a warning in lenient mode.
final class UndeclaredProperty extends Violation {
  /// Creates the violation.
  UndeclaredProperty({
    required super.severity,
    required super.location,
    required this.error,
    super.operation,
    super.request,
  }) : super(message: error.message);

  /// The schema error describing the property.
  final SchemaError error;

  @override
  String? get jsonPath => error.path;

  @override
  String get kind => 'undeclared-property';

  @override
  UndeclaredProperty withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => UndeclaredProperty(
    severity: severity ?? this.severity,
    location: location,
    error: error,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

/// The operation is marked `deprecated` in the spec.
final class DeprecatedOperation extends Violation {
  /// Creates the violation.
  const DeprecatedOperation({
    required super.severity,
    super.operation,
    super.request,
  }) : super(
         location: ViolationLocation.route,
         message: 'the operation is deprecated',
       );

  @override
  String get kind => 'deprecated-operation';

  @override
  DeprecatedOperation withContext({
    Severity? severity,
    String? operation,
    String? request,
  }) => DeprecatedOperation(
    severity: severity ?? this.severity,
    operation: operation ?? this.operation,
    request: request ?? this.request,
  );
}

String _noun(ViolationLocation location) => switch (location) {
  ViolationLocation.requestPath => 'path parameter',
  ViolationLocation.requestQuery => 'query parameter',
  ViolationLocation.requestHeader => 'request header',
  ViolationLocation.requestCookie => 'cookie',
  ViolationLocation.responseHeader => 'response header',
  _ => 'value',
};
