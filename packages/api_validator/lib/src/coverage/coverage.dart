import 'package:meta/meta.dart';

import '../spec/openapi_spec.dart';
import '../spec/operation.dart';

/// How thoroughly one operation was exercised.
@immutable
final class OperationCoverage {
  /// Creates an operation coverage entry.
  OperationCoverage({
    required this.operation,
    required List<String> declaredResponses,
    Map<String, int> exercisedResponses = const {},
    this.requestCount = 0,
    this.operationId,
  }) : declaredResponses = List.unmodifiable(declaredResponses),
       exercisedResponses = Map.unmodifiable(exercisedResponses);

  /// The operation key, for example `GET /users/{id}`.
  final String operation;

  /// The `operationId`, if declared.
  final String? operationId;

  /// Response keys declared in the spec (`200`, `4XX`, `default`).
  final List<String> declaredResponses;

  /// How many times each declared response key was received.
  final Map<String, int> exercisedResponses;

  /// How many requests were routed to this operation.
  final int requestCount;

  /// Whether at least one request reached this operation.
  bool get isExercised => requestCount > 0;

  /// Declared response keys that were never received.
  List<String> get missingResponses => [
    for (final key in declaredResponses)
      if (!exercisedResponses.containsKey(key)) key,
  ];

  /// Merges two entries for the same operation.
  OperationCoverage merge(OperationCoverage other) {
    final responses = Map<String, int>.of(exercisedResponses);
    for (final MapEntry(:key, :value) in other.exercisedResponses.entries) {
      responses.update(key, (count) => count + value, ifAbsent: () => value);
    }
    return OperationCoverage(
      operation: operation,
      operationId: operationId ?? other.operationId,
      declaredResponses: {
        ...declaredResponses,
        ...other.declaredResponses,
      }.toList(),
      exercisedResponses: responses,
      requestCount: requestCount + other.requestCount,
    );
  }

  /// Serializes this entry.
  Map<String, Object?> toJson() => {
    'operation': operation,
    if (operationId != null) 'operationId': operationId,
    'declaredResponses': declaredResponses,
    'exercisedResponses': exercisedResponses,
    'requestCount': requestCount,
  };

  /// Restores an entry produced by [toJson].
  factory OperationCoverage.fromJson(Map<String, Object?> json) =>
      OperationCoverage(
        operation: json['operation']! as String,
        operationId: json['operationId'] as String?,
        declaredResponses: [
          for (final key in json['declaredResponses']! as List<Object?>) '$key',
        ],
        exercisedResponses: {
          for (final MapEntry(:key, :value)
              in (json['exercisedResponses']! as Map<String, Object?>).entries)
            key: (value! as num).toInt(),
        },
        requestCount: (json['requestCount']! as num).toInt(),
      );
}

/// Which operations and responses of a spec the tests exercised.
///
/// Reports from separate test files (which run in separate isolates) can be
/// combined with [merge], or with the `coverage` command of the CLI.
@immutable
final class CoverageReport {
  /// Creates a report from [operations].
  CoverageReport(List<OperationCoverage> operations)
    : operations = List.unmodifiable(operations);

  /// A report for [spec] in which nothing has been exercised yet.
  factory CoverageReport.empty(OpenApiSpec spec) => CoverageReport([
    for (final operation in spec.operations) _emptyEntry(operation),
  ]);

  /// Restores a report produced by [toJson].
  factory CoverageReport.fromJson(Map<String, Object?> json) => CoverageReport([
    for (final entry in json['operations']! as List<Object?>)
      OperationCoverage.fromJson(entry! as Map<String, Object?>),
  ]);

  /// One entry per operation in the spec.
  final List<OperationCoverage> operations;

  /// Number of operations in the spec.
  int get totalOperations => operations.length;

  /// Number of operations that received at least one request.
  int get exercisedOperations =>
      operations.where((entry) => entry.isExercised).length;

  /// Number of declared responses across all operations.
  int get totalResponses =>
      operations.fold(0, (sum, entry) => sum + entry.declaredResponses.length);

  /// Number of declared responses that were received at least once.
  int get exercisedResponses => operations.fold(
    0,
    (sum, entry) =>
        sum + entry.declaredResponses.length - entry.missingResponses.length,
  );

  /// Share of operations exercised, between 0 and 1.
  double get operationRatio =>
      totalOperations == 0 ? 1 : exercisedOperations / totalOperations;

  /// Share of declared responses exercised, between 0 and 1.
  double get responseRatio =>
      totalResponses == 0 ? 1 : exercisedResponses / totalResponses;

  /// Operations that were never called.
  List<OperationCoverage> get untested => [
    for (final entry in operations)
      if (!entry.isExercised) entry,
  ];

  /// The entry for [operation] (`METHOD /path`), if any.
  OperationCoverage? operator [](String operation) {
    for (final entry in operations) {
      if (entry.operation == operation || entry.operationId == operation) {
        return entry;
      }
    }
    return null;
  }

  /// Combines this report with [other], summing counts.
  CoverageReport merge(CoverageReport other) {
    final merged = <String, OperationCoverage>{
      for (final entry in operations) entry.operation: entry,
    };
    for (final entry in other.operations) {
      merged.update(
        entry.operation,
        (existing) => existing.merge(entry),
        ifAbsent: () => entry,
      );
    }
    return CoverageReport(merged.values.toList());
  }

  /// Serializes the report.
  Map<String, Object?> toJson() => {
    'operations': [for (final entry in operations) entry.toJson()],
    'summary': {
      'operations': {
        'total': totalOperations,
        'exercised': exercisedOperations,
      },
      'responses': {'total': totalResponses, 'exercised': exercisedResponses},
    },
  };

  /// A readable multi-line summary.
  String toText({bool showAll = false}) {
    final buffer = StringBuffer()
      ..writeln(
        'API coverage: $exercisedOperations/$totalOperations operations '
        '(${_percent(operationRatio)}), $exercisedResponses/$totalResponses '
        'responses (${_percent(responseRatio)})',
      );
    for (final entry in operations) {
      final missing = entry.missingResponses;
      if (!showAll && entry.isExercised && missing.isEmpty) continue;
      if (!entry.isExercised) {
        buffer.writeln('  ✗ ${entry.operation}  never called');
      } else if (missing.isNotEmpty) {
        buffer.writeln(
          '  ~ ${entry.operation}  untested responses: ${missing.join(', ')}',
        );
      } else {
        buffer.writeln('  ✓ ${entry.operation}');
      }
    }
    return buffer.toString();
  }
}

String _percent(double ratio) => '${(ratio * 100).toStringAsFixed(1)}%';

OperationCoverage _emptyEntry(ApiOperation operation) => OperationCoverage(
  operation: operation.key,
  operationId: operation.operationId,
  declaredResponses: operation.responses.keys.toList(),
);

/// Accumulates coverage as exchanges are checked.
final class CoverageTracker {
  /// Creates a tracker for every operation of [spec].
  CoverageTracker(this.spec);

  /// The spec being covered.
  final OpenApiSpec spec;

  final Map<String, int> _requests = {};
  final Map<String, Map<String, int>> _responses = {};

  /// Records a request routed to [operation] and, when a response arrived,
  /// the matched [responseKey].
  void record(ApiOperation operation, {String? responseKey}) {
    _requests.update(operation.key, (count) => count + 1, ifAbsent: () => 1);
    if (responseKey != null) {
      _responses
          .putIfAbsent(operation.key, () => {})
          .update(responseKey, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  /// Forgets everything recorded so far.
  void reset() {
    _requests.clear();
    _responses.clear();
  }

  /// A snapshot of the coverage so far.
  CoverageReport get report => CoverageReport([
    for (final operation in spec.operations)
      OperationCoverage(
        operation: operation.key,
        operationId: operation.operationId,
        declaredResponses: operation.responses.keys.toList(),
        exercisedResponses: _responses[operation.key] ?? const {},
        requestCount: _requests[operation.key] ?? 0,
      ),
  ]);
}
