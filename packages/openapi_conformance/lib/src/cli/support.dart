import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../core/checker.dart';
import '../report/reporters.dart';
import '../spec/openapi_spec.dart';
import '../spec/spec_exception.dart';

/// An error in how the CLI was invoked or configured. Exit code 2.
final class CliException implements Exception {
  /// Creates the exception.
  const CliException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => message;
}

/// Exit code for success.
const exitSuccess = 0;

/// Exit code for conformance failures.
const exitFailure = 1;

/// Exit code for usage and configuration errors.
const exitUsage = 2;

/// Output formats shared by the commands.
enum Reporter {
  /// Human readable text.
  text,

  /// JSON document.
  json,

  /// JUnit XML.
  junit,

  /// GitHub Actions workflow commands.
  github;

  /// Parses a `--reporter` value.
  static Reporter parse(String value) => Reporter.values.firstWhere(
    (reporter) => reporter.name == value,
    orElse: () => throw CliException('Unknown reporter "$value".'),
  );
}

/// Base class for commands that write to injectable sinks.
abstract class CliCommand extends Command<int> {
  /// Creates a command writing to [out] and [err].
  CliCommand(this.out, this.err);

  /// Standard output.
  final StringSink out;

  /// Standard error.
  final StringSink err;

  @override
  void printUsage() => out.writeln(usage);

  /// The parsed value of a string option.
  String? stringOption(String name) => argResults![name] as String?;

  /// The parsed value of a multi option.
  List<String> multiOption(String name) =>
      (argResults![name] as List<Object?>).cast<String>();

  /// The parsed value of a flag.
  bool flag(String name) => argResults![name] as bool;
}

/// Loads a spec from [path], converting failures into [CliException]s.
OpenApiSpec loadSpec(String path) {
  if (!File(path).existsSync()) {
    throw CliException('Spec file not found: $path');
  }
  try {
    return OpenApiSpec.fromFileSync(path);
  } on OpenApiSpecException catch (error) {
    throw CliException('Could not load spec $path: ${error.message}');
  }
}

/// A path relative to the working directory with forward slashes, as
/// expected by GitHub annotations.
String displayPath(String path) {
  final relative = p.isWithin(p.current, path) || p.equals(p.current, path)
      ? p.relative(path)
      : path;
  return relative.replaceAll(r'\', '/');
}

/// One checked item: a fixture file or a recorded exchange.
final class CheckItem {
  /// Creates an item.
  const CheckItem(this.source, this.result);

  /// Where the item comes from, for example `test/fixtures/pet.json` or
  /// `session.har#3`.
  final String source;

  /// The conformance result.
  final ConformanceResult result;

  /// [source] without a `#entry` suffix.
  String get file {
    final index = source.lastIndexOf('#');
    return index < 0 ? source : source.substring(0, index);
  }
}

/// Renders [items] in the requested format.
String renderItems(List<CheckItem> items, Reporter reporter) {
  final errors = items.fold(0, (sum, i) => sum + i.result.errors.length);
  final warnings = items.fold(0, (sum, i) => sum + i.result.warnings.length);
  final summary =
      '${items.length} item${items.length == 1 ? '' : 's'} checked, '
      '$errors error${errors == 1 ? '' : 's'}, '
      '$warnings warning${warnings == 1 ? '' : 's'}';
  switch (reporter) {
    case Reporter.text:
      final buffer = StringBuffer();
      for (final item in items) {
        final result = item.result;
        final mark = result.violations.isEmpty
            ? '✓'
            : result.isConforming
            ? '!'
            : '✗';
        buffer.writeln('$mark ${item.source}  (${result.label})');
        for (final violation in result.violations) {
          buffer.writeln(
            '    ${violation.isError ? 'error' : 'warning'}: $violation',
          );
        }
      }
      buffer.write(summary);
      return buffer.toString();
    case Reporter.json:
      return const JsonEncoder.withIndent('  ').convert({
        'items': [
          for (final item in items)
            {
              'source': item.source,
              if (item.result.operation != null)
                'operation': item.result.operation!.key,
              if (item.result.exchange.response != null)
                'status': item.result.exchange.response!.statusCode,
              'conforming': item.result.isConforming,
              'violations': [
                for (final violation in item.result.violations)
                  violation.toJson(),
              ],
            },
        ],
        'summary': {
          'items': items.length,
          'errors': errors,
          'warnings': warnings,
        },
      });
    case Reporter.junit:
      final failures = items.where((i) => !i.result.isConforming).length;
      final buffer = StringBuffer()
        ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
        ..writeln(
          '<testsuite name="openapi_conformance" tests="${items.length}" '
          'failures="$failures">',
        );
      for (final item in items) {
        final name = xmlEscape('${item.source}: ${item.result.label}');
        if (item.result.isConforming) {
          buffer.writeln('  <testcase name="$name"/>');
          continue;
        }
        buffer.writeln('  <testcase name="$name">');
        for (final violation in item.result.errors) {
          buffer.writeln(
            '    <failure type="${violation.kind}" '
            'message="${xmlEscape(violation.toString())}"/>',
          );
        }
        buffer.writeln('  </testcase>');
      }
      buffer.write('</testsuite>');
      return buffer.toString();
    case Reporter.github:
      final buffer = StringBuffer();
      for (final item in items) {
        for (final violation in item.result.violations) {
          buffer.writeln(
            ConformanceReporter.githubAnnotation(
              violation,
              file: item.file,
              line: 1,
            ),
          );
        }
      }
      buffer.write(summary);
      return buffer.toString();
  }
}

/// Whether [items] should fail the run.
bool itemsFail(List<CheckItem> items, {required bool failOnWarnings}) =>
    items.any(
      (item) =>
          !item.result.isConforming ||
          (failOnWarnings && item.result.violations.isNotEmpty),
    );

/// Escapes text for XML attributes.
String xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// A GitHub Actions workflow command.
String githubCommand(
  String command,
  String message, {
  String? title,
  String? file,
  int? line,
}) {
  String data(String value) => value
      .replaceAll('%', '%25')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');
  String property(String value) =>
      data(value).replaceAll(':', '%3A').replaceAll(',', '%2C');
  final properties = [
    if (file != null) 'file=${property(file)}',
    if (line != null) 'line=$line',
    if (title != null) 'title=${property(title)}',
  ];
  final head = properties.isEmpty
      ? command
      : '$command ${properties.join(',')}';
  return '::$head::${data(message)}';
}
