import 'dart:convert';
import 'dart:io';

import '../core/checker.dart';
import '../core/exchange.dart';
import '../core/options.dart';
import '../core/violation.dart';
import '../har/har.dart';
import '../schema/schema_error.dart';
import '../schema/schema_validator.dart';
import '../spec/media_type.dart';
import '../spec/openapi_spec.dart';
import '../spec/operation.dart';
import 'config.dart';
import 'support.dart';

/// Checks fixture files and HAR recordings against a spec.
final class FixtureChecker {
  /// Creates a checker for [spec].
  FixtureChecker(
    this.spec, {
    this.mode = ValidationMode.strict,
    this.unmatched = UnmatchedPolicy.warning,
  }) : _validator = SchemaValidator(spec);

  /// The spec to check against.
  final OpenApiSpec spec;

  /// Strict or lenient.
  final ValidationMode mode;

  /// How HAR requests that match no operation are reported.
  final UnmatchedPolicy unmatched;

  final SchemaValidator _validator;

  Severity get _strictSeverity =>
      mode == ValidationMode.strict ? Severity.error : Severity.warning;

  /// Checks one fixture file.
  CheckItem checkFixture(FixtureSpec fixture) {
    final operation = spec.operation(fixture.operation);
    if (operation == null) {
      throw CliException(
        'Fixture ${displayPath(fixture.path)}: no operation matches '
        '"${fixture.operation}". Use an operationId or "METHOD /path".',
      );
    }
    final file = File(fixture.path);
    if (!file.existsSync()) {
      throw CliException('Fixture not found: ${displayPath(fixture.path)}');
    }
    final source = displayPath(fixture.path);
    final text = file.readAsStringSync();
    final violations = <Violation>[];
    Object? body;
    var parsed = false;
    try {
      body = jsonDecode(text);
      parsed = true;
    } on FormatException catch (error) {
      violations.add(
        InvalidJson(
          severity: Severity.error,
          location: fixture.direction == FixtureDirection.request
              ? ViolationLocation.requestBody
              : ViolationLocation.responseBody,
          details: error.message,
          operation: operation.key,
          request: source,
        ),
      );
    }

    String? responseKey;
    if (parsed) {
      if (fixture.direction == FixtureDirection.request) {
        _checkRequest(operation, body, source, violations);
      } else {
        responseKey = operation.responseKeyFor(fixture.status!);
        _checkResponse(
          operation,
          fixture.status!,
          responseKey,
          body,
          source,
          violations,
        );
      }
    }

    final request = ExchangeRequest(
      method: operation.method,
      uri: Uri(path: operation.path),
      body: fixture.direction == FixtureDirection.request ? body : null,
    );
    return CheckItem(
      source,
      ValidationResult(
        exchange: Exchange(
          request: request,
          response: fixture.direction == FixtureDirection.response
              ? ExchangeResponse(statusCode: fixture.status!, body: body)
              : null,
        ),
        violations: violations,
        operation: operation,
        responseKey: responseKey,
      ),
    );
  }

  void _checkRequest(
    ApiOperation operation,
    Object? body,
    String source,
    List<Violation> violations,
  ) {
    final declared = operation.requestBody;
    if (declared == null || declared.content.isEmpty) {
      violations.add(
        UnsupportedContentType(
          severity: _strictSeverity,
          location: ViolationLocation.requestBody,
          contentType: 'application/json',
          declared: const [],
          operation: operation.key,
          request: source,
        ),
      );
      return;
    }
    _validate(
      operation,
      declared.content,
      body,
      ViolationLocation.requestBody,
      SchemaDirection.request,
      source,
      violations,
    );
  }

  void _checkResponse(
    ApiOperation operation,
    int status,
    String? responseKey,
    Object? body,
    String source,
    List<Violation> violations,
  ) {
    if (responseKey == null) {
      violations.add(
        UndeclaredStatus(
          severity: _strictSeverity,
          statusCode: status,
          declaredStatuses: operation.responses.keys.toList(),
          operation: operation.key,
          request: source,
        ),
      );
      return;
    }
    final content = operation.responses[responseKey]!.content;
    if (content.isEmpty) {
      violations.add(
        UnsupportedContentType(
          severity: _strictSeverity,
          location: ViolationLocation.responseBody,
          contentType: 'application/json',
          declared: const [],
          operation: operation.key,
          request: source,
        ),
      );
      return;
    }
    _validate(
      operation,
      content,
      body,
      ViolationLocation.responseBody,
      SchemaDirection.response,
      source,
      violations,
    );
  }

  void _validate(
    ApiOperation operation,
    Map<String, ApiMediaType> content,
    Object? body,
    ViolationLocation location,
    SchemaDirection direction,
    String source,
    List<Violation> violations,
  ) {
    final key = MediaTypes.select(content.keys, 'application/json');
    if (key == null) {
      violations.add(
        UnsupportedContentType(
          severity: Severity.error,
          location: location,
          contentType: 'application/json',
          declared: content.keys.toList(),
          operation: operation.key,
          request: source,
        ),
      );
      return;
    }
    final schema = content[key]!.schema;
    if (schema == null) return;
    for (final error in _validator.validate(
      schema,
      body,
      direction: direction,
    )) {
      if (error.isUndeclaredProperty) {
        violations.add(
          UndeclaredProperty(
            severity: _strictSeverity,
            location: location,
            error: error,
            operation: operation.key,
            request: source,
          ),
        );
      } else {
        violations.add(
          SchemaMismatch(
            severity: _relaxed(error) ? _strictSeverity : Severity.error,
            location: location,
            error: error,
            operation: operation.key,
            request: source,
          ),
        );
      }
    }
  }

  bool _relaxed(SchemaError error) =>
      error.keyword == 'readOnly' || error.keyword == 'writeOnly';

  /// Checks every exchange recorded in the HAR file at [path].
  List<CheckItem> checkHar(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw CliException('HAR file not found: ${displayPath(path)}');
    }
    final List<Exchange> exchanges;
    try {
      exchanges = parseHar(file.readAsStringSync());
    } on FormatException catch (error) {
      throw CliException('${displayPath(path)}: ${error.message}');
    }
    final checker = ApiValidator(
      spec,
      options: ValidatorOptions(mode: mode, unmatchedRequests: unmatched),
    );
    final source = displayPath(path);
    final items = <CheckItem>[];
    for (final (index, exchange) in exchanges.indexed) {
      final result = checker.check(exchange);
      if (result.skipped) continue;
      items.add(CheckItem('$source#${index + 1}', result));
    }
    return items;
  }
}
