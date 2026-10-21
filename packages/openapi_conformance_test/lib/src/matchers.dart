import 'dart:convert';

import 'package:matcher/matcher.dart';
import 'package:openapi_conformance/openapi_conformance.dart';

/// Matches when no [Severity.error] violation was found. Warnings are
/// allowed.
///
/// Accepts a [ConformanceChecker] (its results since the last reset), a
/// [ConformanceResult], or an `Iterable<Violation>`.
///
/// ```dart
/// expect(checker, isConforming);
/// ```
const Matcher isConforming = _ViolationsMatcher(includeWarnings: false);

/// Matches when no violation at all, error or warning, was found.
///
/// Accepts the same values as [isConforming].
const Matcher hasNoViolations = _ViolationsMatcher(includeWarnings: true);

List<Violation>? _violationsOf(Object? item) => switch (item) {
  final ConformanceChecker checker => checker.violations,
  final ConformanceResult result => result.violations,
  final Iterable<Violation> violations => violations.toList(),
  _ => null,
};

const _unsupported =
    'is not a ConformanceChecker, ConformanceResult or Iterable<Violation>';

final class _ViolationsMatcher extends Matcher {
  const _ViolationsMatcher({required this.includeWarnings});

  final bool includeWarnings;

  List<Violation> _relevant(List<Violation> violations) => [
    for (final violation in violations)
      if (includeWarnings || violation.isError) violation,
  ];

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    final violations = _violationsOf(item);
    if (violations == null) return false;
    final relevant = _relevant(violations);
    matchState['violations'] = relevant;
    return relevant.isEmpty;
  }

  @override
  Description describe(Description description) => description.add(
    includeWarnings
        ? 'an exchange without spec violations'
        : 'an exchange conforming to the spec',
  );

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) {
    final violations = matchState['violations'];
    if (violations is! List<Violation>) {
      return mismatchDescription.add(_unsupported);
    }
    mismatchDescription.add(
      'has ${violations.length} violation${violations.length == 1 ? '' : 's'}:',
    );
    for (final violation in violations) {
      mismatchDescription.add(
        '\n  - ${violation.isError ? 'error' : 'warning'}: $violation',
      );
    }
    return mismatchDescription;
  }
}

/// Matches when at least one violation satisfies every given criterion.
///
/// [type] compares the runtime type (for example `SchemaMismatch`). [kind]
/// compares [Violation.kind] (for example `schema-mismatch`). [message] is
/// a substring or a [Matcher] applied to [Violation.message].
///
/// ```dart
/// expect(checker, hasViolation(type: UndeclaredStatus));
/// expect(result, hasViolation(jsonPath: r'$.address.zip'));
/// ```
Matcher hasViolation({
  Type? type,
  String? kind,
  ViolationLocation? location,
  String? jsonPath,
  Object? message,
  Severity? severity,
}) => _HasViolation(
  type: type,
  kind: kind,
  location: location,
  jsonPath: jsonPath,
  message: message == null
      ? null
      : (message is Matcher ? message : contains(message)),
  severity: severity,
);

final class _HasViolation extends Matcher {
  const _HasViolation({
    this.type,
    this.kind,
    this.location,
    this.jsonPath,
    this.message,
    this.severity,
  });

  final Type? type;
  final String? kind;
  final ViolationLocation? location;
  final String? jsonPath;
  final Matcher? message;
  final Severity? severity;

  bool _accepts(Violation violation) =>
      (type == null || violation.runtimeType == type) &&
      (kind == null || violation.kind == kind) &&
      (location == null || violation.location == location) &&
      (jsonPath == null || violation.jsonPath == jsonPath) &&
      (severity == null || violation.severity == severity) &&
      (message == null || message!.matches(violation.message, {}));

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    final violations = _violationsOf(item);
    if (violations == null) return false;
    matchState['violations'] = violations;
    return violations.any(_accepts);
  }

  @override
  Description describe(Description description) {
    final criteria = <String>[
      if (type != null) 'type $type',
      if (kind != null) 'kind "$kind"',
      if (location != null) 'location ${location!.label}',
      if (jsonPath != null) 'JSON path $jsonPath',
      if (severity != null) 'severity ${severity!.name}',
    ];
    description.add('a violation');
    if (criteria.isNotEmpty) description.add(' with ${criteria.join(', ')}');
    if (message != null) {
      description.add(' and message ').addDescriptionOf(message);
    }
    return description;
  }

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) {
    final violations = matchState['violations'];
    if (violations is! List<Violation>) {
      return mismatchDescription.add(_unsupported);
    }
    if (violations.isEmpty) return mismatchDescription.add('has no violations');
    mismatchDescription.add('has only:');
    for (final violation in violations) {
      mismatchDescription.add('\n  - ${violation.runtimeType}: $violation');
    }
    return mismatchDescription;
  }
}

/// Matches a [ConformanceChecker] or [CoverageReport] in which [operation]
/// (`operationId` or `METHOD /path`) was called.
///
/// When [status] is given (an `int` such as `404`, or a response key such as
/// `'4XX'` or `'default'`), that response must have been received too.
///
/// ```dart
/// expect(checker, exercised('getPet', status: 404));
/// ```
Matcher exercised(String operation, {Object? status}) {
  if (status != null && status is! int && status is! String) {
    throw ArgumentError.value(status, 'status', 'must be an int or a String');
  }
  return _Exercised(operation, status);
}

final class _Exercised extends Matcher {
  const _Exercised(this.operation, this.status);

  final String operation;
  final Object? status;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    final report = switch (item) {
      final ConformanceChecker checker => checker.coverage,
      final CoverageReport report => report,
      _ => null,
    };
    if (report == null) return false;
    final entry = report[operation] ?? _byReference(report);
    matchState['entry'] = entry;
    matchState['report'] = true;
    if (entry == null || !entry.isExercised) return false;
    if (status == null) return true;
    return _statusKey(entry) != null;
  }

  OperationCoverage? _byReference(CoverageReport report) {
    final space = operation.indexOf(' ');
    if (space < 0) return null;
    return report['${operation.substring(0, space).toUpperCase()} '
        '${operation.substring(space + 1).trim()}'];
  }

  String? _statusKey(OperationCoverage entry) {
    final exercisedKeys = entry.exercisedResponses.keys;
    final wanted = status;
    if (wanted is String) {
      return exercisedKeys.firstWhereOrNullCaseInsensitive(wanted);
    }
    final code = wanted! as int;
    final declared = entry.declaredResponses.map((k) => k.toUpperCase());
    final exact = '$code';
    final range = '${code ~/ 100}XX';
    final key = declared.contains(exact)
        ? exact
        : declared.contains(range)
        ? range
        : 'default';
    return exercisedKeys.firstWhereOrNullCaseInsensitive(key);
  }

  @override
  Description describe(Description description) {
    description.add('coverage in which "$operation" was called');
    if (status != null) description.add(' and returned $status');
    return description;
  }

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) {
    if (matchState['report'] != true) {
      return mismatchDescription.add(
        'is not a ConformanceChecker or CoverageReport',
      );
    }
    final entry = matchState['entry'];
    if (entry is! OperationCoverage) {
      return mismatchDescription.add('has no operation "$operation"');
    }
    if (!entry.isExercised) return mismatchDescription.add('was never called');
    final received = entry.exercisedResponses.keys.join(', ');
    return mismatchDescription.add('only returned: $received');
  }
}

extension on Iterable<String> {
  String? firstWhereOrNullCaseInsensitive(String wanted) {
    for (final value in this) {
      if (value.toUpperCase() == wanted.toUpperCase()) return value;
    }
    return null;
  }
}

/// Matches a JSON value (a decoded `Map`/`List`, or a JSON `String`) that
/// is a valid [status] response body of [operation].
///
/// Use it to check hand-written fixtures without any HTTP client:
///
/// ```dart
/// expect(
///   File('test/fixtures/pet.json').readAsStringSync(),
///   conformsToResponse(spec, 'getPet'),
/// );
/// ```
///
/// In [ConformanceMode.lenient], undeclared properties are tolerated.
Matcher conformsToResponse(
  OpenApiSpec spec,
  String operation, {
  int status = 200,
  String? mediaType,
  ConformanceMode mode = ConformanceMode.strict,
}) {
  final op = spec.requireOperation(operation);
  final response = op.responseFor(status);
  if (response == null) {
    throw ArgumentError.value(
      status,
      'status',
      '${op.key} declares no response for this status',
    );
  }
  return _ConformsTo(
    spec,
    _schemaOf(response.content, mediaType, '${op.key} -> $status'),
    '${op.key} -> ${response.statusKey} response',
    SchemaDirection.response,
    mode,
  );
}

/// Matches a JSON value that is a valid request body of [operation].
Matcher conformsToRequestBody(
  OpenApiSpec spec,
  String operation, {
  String? mediaType,
  ConformanceMode mode = ConformanceMode.strict,
}) {
  final op = spec.requireOperation(operation);
  final body = op.requestBody;
  if (body == null) {
    throw ArgumentError.value(
      operation,
      'operation',
      '${op.key} declares no request body',
    );
  }
  return _ConformsTo(
    spec,
    _schemaOf(body.content, mediaType, '${op.key} request'),
    '${op.key} request body',
    SchemaDirection.request,
    mode,
  );
}

/// Matches a JSON value that is valid against `components.schemas[name]`.
Matcher conformsToSchema(
  OpenApiSpec spec,
  String componentName, {
  SchemaDirection direction = SchemaDirection.none,
  ConformanceMode mode = ConformanceMode.strict,
}) {
  final schema = spec.componentSchema(componentName);
  if (schema == null) {
    throw ArgumentError.value(
      componentName,
      'componentName',
      'not found in components.schemas',
    );
  }
  return _ConformsTo(spec, schema, 'schema "$componentName"', direction, mode);
}

Object? _schemaOf(
  Map<String, ApiMediaType> content,
  String? mediaType,
  String context,
) {
  final key = MediaTypes.select(content.keys, mediaType);
  if (key == null) {
    throw ArgumentError(
      '$context declares no ${mediaType ?? 'JSON'} content; declared: '
      '${content.keys.join(', ')}',
    );
  }
  return content[key]!.schema;
}

final class _ConformsTo extends Matcher {
  const _ConformsTo(
    this.spec,
    this.schema,
    this.label,
    this.direction,
    this.mode,
  );

  final OpenApiSpec spec;
  final Object? schema;
  final String label;
  final SchemaDirection direction;
  final ConformanceMode mode;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    Object? value = item;
    if (item is String) {
      try {
        value = jsonDecode(item);
      } on FormatException catch (error) {
        matchState['invalidJson'] = error.message;
        return false;
      }
    }
    final errors = SchemaValidator(spec)
        .validate(schema, value, direction: direction)
        .where(
          (error) =>
              mode == ConformanceMode.strict || !error.isUndeclaredProperty,
        )
        .toList();
    matchState['errors'] = errors;
    return errors.isEmpty;
  }

  @override
  Description describe(Description description) =>
      description.add('a value conforming to $label');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) {
    final invalid = matchState['invalidJson'];
    if (invalid != null) {
      return mismatchDescription.add('is not valid JSON: $invalid');
    }
    final errors = matchState['errors'];
    if (errors is! List<SchemaError>) return mismatchDescription;
    mismatchDescription.add(
      'has ${errors.length} problem${errors.length == 1 ? '' : 's'}:',
    );
    for (final error in errors) {
      mismatchDescription.add('\n  - $error');
    }
    return mismatchDescription;
  }
}
