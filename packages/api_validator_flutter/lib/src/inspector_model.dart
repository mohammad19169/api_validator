import 'dart:async';
import 'dart:convert';

import 'package:api_validator/api_validator.dart';
import 'package:flutter/foundation.dart';

/// Holds the results shown by the inspector and keeps them in sync with a
/// [ApiValidator].
///
/// Bursts of results are coalesced into a single notification per
/// microtask, so a screen that fires many requests at once does not
/// rebuild the overlay for each of them.
class InspectorModel extends ChangeNotifier {
  /// Creates a model that follows [checker].
  InspectorModel(ApiValidator checker) : _checker = checker {
    _subscribe();
    _results = _snapshot();
  }

  ApiValidator _checker;
  StreamSubscription<ValidationResult>? _subscription;
  List<ValidationResult> _results = const [];
  bool _scheduled = false;
  bool _disposed = false;

  /// The checker whose results are shown.
  ApiValidator get checker => _checker;

  /// Switches to another checker and reloads its results.
  set checker(ApiValidator value) {
    if (identical(value, _checker)) return;
    unawaited(_subscription?.cancel());
    _checker = value;
    _subscribe();
    refresh();
  }

  /// Recorded results, newest first.
  List<ValidationResult> get results => _results;

  /// Results without errors or warnings.
  int get conformingCount => _results
      .where((result) => result.isValid && result.warnings.isEmpty)
      .length;

  /// Results without errors but with at least one warning.
  int get warningCount => _results
      .where((result) => result.isValid && result.warnings.isNotEmpty)
      .length;

  /// Results with at least one error.
  int get errorCount => _results.where((result) => !result.isValid).length;

  /// Reloads the results from [checker] and notifies listeners.
  void refresh() {
    if (_disposed) return;
    _results = _snapshot();
    notifyListeners();
  }

  /// Clears the checker's recorded results.
  void clear() {
    _checker.reset();
    refresh();
  }

  void _subscribe() {
    _subscription = _checker.onResult.listen(_onResult);
  }

  void _onResult(ValidationResult _) {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      refresh();
    });
  }

  List<ValidationResult> _snapshot() =>
      List.unmodifiable(_checker.results.reversed);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}

/// Formats an exchange body for display.
///
/// JSON (decoded values, JSON strings and UTF-8 bytes) is pretty-printed.
/// Returns `null` when there is no body.
String? formatBody(Object? body) {
  if (body == null) return null;
  if (body is Uint8List) {
    if (body.isEmpty) return null;
    return formatBody(utf8.decode(body, allowMalformed: true));
  }
  if (body is String) {
    if (body.trim().isEmpty) return null;
    try {
      return _pretty(jsonDecode(body));
    } on FormatException {
      return body;
    }
  }
  return _pretty(body);
}

String _pretty(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ', _toEncodable).convert(value);
  } on Object {
    return '$value';
  }
}

Object? _toEncodable(Object? value) => '$value';

/// A plain-text report of one checked exchange, suitable for pasting into
/// a bug report or chat.
String exchangeReport(ValidationResult result) {
  final exchange = result.exchange;
  final request = exchange.request;
  final response = exchange.response;
  final operation = result.operation;
  final buffer = StringBuffer()
    ..writeln(
      response == null
          ? '${request.method} ${request.uri}'
          : '${request.method} ${request.uri} -> ${response.statusCode}',
    )
    ..writeln(
      operation == null
          ? 'Operation: not found in spec'
          : 'Operation: ${operation.key}'
                '${operation.operationId == null ? '' : ' (${operation.operationId})'}',
    );
  if (response != null) {
    buffer.writeln(
      'Response: ${response.statusCode}'
      '${result.responseKey == null ? ' (not declared)' : ' (declared as ${result.responseKey})'}',
    );
  }
  if (result.violations.isEmpty) {
    buffer.writeln('Violations: none');
  } else {
    buffer.writeln('Violations:');
    for (final violation in result.violations) {
      buffer.writeln(
        '  ${violation.isError ? 'error  ' : 'warning'} $violation',
      );
    }
  }
  final requestBody = formatBody(request.body);
  if (requestBody != null) {
    buffer
      ..writeln('Request body:')
      ..writeln(requestBody);
  }
  final responseBody = formatBody(response?.body);
  if (responseBody != null) {
    buffer
      ..writeln('Response body:')
      ..writeln(responseBody);
  }
  return buffer.toString().trimRight();
}
