import 'dart:convert';

import '../core/checker.dart';
import '../core/violation.dart';
import '../coverage/coverage.dart';

/// Turns validation results into text for humans, CI systems or tools.
///
/// ```dart
/// print(ValidationReporter.text(checker.results));
/// File('report.xml').writeAsStringSync(
///   ValidationReporter.junit(checker.results),
/// );
/// ```
abstract final class ValidationReporter {
  /// A readable summary listing every exchange that has violations.
  ///
  /// Conforming exchanges are listed too when [verbose] is `true`.
  static String text(
    Iterable<ValidationResult> results, {
    bool verbose = false,
  }) {
    final list = results.toList();
    final errors = list.fold(0, (sum, r) => sum + r.errors.length);
    final warnings = list.fold(0, (sum, r) => sum + r.warnings.length);
    final buffer = StringBuffer();
    for (final result in list) {
      if (!verbose && result.violations.isEmpty) continue;
      buffer.writeln(result);
    }
    buffer.write(
      '${list.length} exchange${list.length == 1 ? '' : 's'} checked, '
      '$errors error${errors == 1 ? '' : 's'}, '
      '$warnings warning${warnings == 1 ? '' : 's'}',
    );
    return buffer.toString();
  }

  /// A JSON document describing [results] and, optionally, [coverage].
  static String json(
    Iterable<ValidationResult> results, {
    CoverageReport? coverage,
  }) => const JsonEncoder.withIndent('  ').convert({
    'results': [
      for (final result in results)
        {
          'request': '${result.exchange.request}',
          if (result.operation != null) 'operation': result.operation!.key,
          if (result.exchange.response != null)
            'status': result.exchange.response!.statusCode,
          'conforming': result.isValid,
          'violations': [for (final v in result.violations) v.toJson()],
        },
    ],
    if (coverage != null) 'coverage': coverage.toJson(),
  });

  /// A JUnit XML report with one test case per exchange, which most CI
  /// systems can display.
  static String junit(
    Iterable<ValidationResult> results, {
    String suiteName = 'api_validator',
  }) {
    final list = results.toList();
    final failures = list.where((r) => !r.isValid).length;
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<testsuite name="${_xml(suiteName)}" tests="${list.length}" '
        'failures="$failures">',
      );
    for (final result in list) {
      buffer.write('  <testcase name="${_xml(result.label)}"');
      if (result.isValid) {
        buffer.writeln('/>');
        continue;
      }
      buffer.writeln('>');
      for (final violation in result.errors) {
        buffer.writeln(
          '    <failure type="${violation.kind}" '
          'message="${_xml(violation.toString())}"/>',
        );
      }
      buffer.writeln('  </testcase>');
    }
    buffer.writeln('</testsuite>');
    return buffer.toString();
  }

  /// GitHub Actions workflow commands that annotate a run with every
  /// violation. Pass [file] (and [line]) to attach them to a source file.
  static String github(
    Iterable<ValidationResult> results, {
    String? file,
    int? line,
  }) {
    final buffer = StringBuffer();
    for (final result in results) {
      for (final violation in result.violations) {
        buffer.writeln(githubAnnotation(violation, file: file, line: line));
      }
    }
    return buffer.toString();
  }

  /// One GitHub Actions annotation for [violation].
  static String githubAnnotation(
    Violation violation, {
    String? file,
    int? line,
    String? title,
  }) {
    final command = violation.isError ? 'error' : 'warning';
    final properties = [
      if (file != null) 'file=${_githubProperty(file)}',
      if (line != null) 'line=$line',
      'title=${_githubProperty(title ?? 'OpenAPI ${violation.kind}')}',
    ].join(',');
    return '::$command $properties::${_githubData(violation.toString())}';
  }
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _githubData(String value) => value
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');

String _githubProperty(String value) =>
    _githubData(value).replaceAll(':', '%3A').replaceAll(',', '%2C');
