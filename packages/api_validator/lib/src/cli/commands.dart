import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import '../core/options.dart';

import '../coverage/coverage.dart';
import '../diff/spec_diff.dart';
import 'config.dart';
import 'fixtures.dart';
import 'support.dart';

/// `check`: validates fixture files and HAR recordings against a spec.
final class CheckCommand extends CliCommand {
  /// Creates the command.
  CheckCommand(super.out, super.err) {
    argParser
      ..addOption('spec', abbr: 's', help: 'OpenAPI spec (JSON or YAML).')
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Config file. Defaults to $defaultConfigFile when present.',
      )
      ..addMultiOption(
        'har',
        help: 'HAR recording to check. Repeatable.',
        splitCommas: false,
      )
      ..addMultiOption(
        'fixture',
        help:
            'Fixture mapping <file>=<operation>:<status>, or '
            '<file>=<operation>:request for request bodies. Repeatable.',
        splitCommas: false,
      )
      ..addOption('mode', allowed: ['strict', 'lenient'])
      ..addOption(
        'unmatched',
        allowed: ['error', 'warning', 'ignore'],
        help: 'How HAR requests matching no operation are reported.',
      )
      ..addOption(
        'reporter',
        abbr: 'r',
        allowed: ['text', 'json', 'junit', 'github'],
        defaultsTo: 'text',
      )
      ..addOption('output', abbr: 'o', help: 'Write the report to a file.')
      ..addFlag(
        'fail-on-warnings',
        negatable: false,
        help: 'Exit with 1 when there are warnings.',
      );
  }

  @override
  String get name => 'check';

  @override
  String get description =>
      'Check saved JSON fixtures and HAR recordings against the spec.';

  @override
  Future<int> run() async {
    final configPath =
        stringOption('config') ??
        (File(defaultConfigFile).existsSync() ? defaultConfigFile : null);
    final config = configPath == null
        ? const CliConfig()
        : CliConfig.load(configPath);
    final specPath = stringOption('spec') ?? config.specPath;
    if (specPath == null) {
      throw UsageException(
        'No spec given. Pass --spec or set "spec" in the config file.',
        usage,
      );
    }
    final spec = loadSpec(specPath);
    final fixtures = [
      ...config.fixtures,
      for (final argument in multiOption('fixture'))
        FixtureSpec.parseArgument(argument),
    ];
    final har = [...config.har, ...multiOption('har')];
    if (fixtures.isEmpty && har.isEmpty) {
      throw UsageException(
        'Nothing to check. Pass --fixture or --har, or list fixtures in the '
        'config file.',
        usage,
      );
    }
    final checker = FixtureChecker(
      spec,
      mode: parseMode(stringOption('mode')) ?? config.mode ?? _strict,
      unmatched:
          parseUnmatched(stringOption('unmatched')) ??
          config.unmatched ??
          _warning,
    );
    final items = [
      for (final fixture in fixtures) checker.checkFixture(fixture),
      for (final file in har) ...checker.checkHar(file),
    ];
    final report = renderItems(
      items,
      Reporter.parse(stringOption('reporter')!),
    );
    final output = stringOption('output');
    if (output == null) {
      out.writeln(report);
    } else {
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(report);
      out.writeln(renderItems(items, Reporter.text).split('\n').last);
      out.writeln('Report written to $output');
    }
    return itemsFail(items, failOnWarnings: flag('fail-on-warnings'))
        ? exitFailure
        : 0;
  }
}

const _strict = ValidationMode.strict;
const _warning = UnmatchedPolicy.warning;

/// `diff`: compares two versions of a spec.
final class DiffCommand extends CliCommand {
  /// Creates the command.
  DiffCommand(super.out, super.err) {
    argParser
      ..addOption(
        'fail-on',
        allowed: ['breaking', 'potentially-breaking', 'none'],
        defaultsTo: 'breaking',
        help: 'Which changes make the command exit with 1.',
      )
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Config file whose fixtures are re-checked against the new spec.',
      )
      ..addOption('mode', allowed: ['strict', 'lenient'])
      ..addOption(
        'reporter',
        abbr: 'r',
        allowed: ['text', 'json', 'github'],
        defaultsTo: 'text',
      );
  }

  @override
  String get name => 'diff';

  @override
  String get description =>
      'Compare two versions of a spec and classify changes for clients.';

  @override
  String get invocation =>
      '${runner!.executableName} diff <old-spec> <new-spec>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 2) {
      throw UsageException('Expected <old-spec> and <new-spec>.', usage);
    }
    final before = loadSpec(rest[0]);
    final after = loadSpec(rest[1]);
    final diff = SpecDiff.compare(before, after);

    final configPath = stringOption('config');
    final items = <CheckItem>[];
    if (configPath != null) {
      final config = CliConfig.load(configPath);
      final checker = FixtureChecker(
        after,
        mode: parseMode(stringOption('mode')) ?? config.mode ?? _strict,
      );
      for (final fixture in config.fixtures) {
        items.add(checker.checkFixture(fixture));
      }
    }
    final broken = [
      for (final item in items)
        if (!item.result.isValid) item,
    ];

    switch (Reporter.parse(stringOption('reporter')!)) {
      case Reporter.text:
        out.writeln(diff.toText());
        if (configPath != null) {
          out.writeln();
          if (broken.isEmpty) {
            out.writeln(
              'All ${items.length} fixtures still conform to the new spec.',
            );
          } else {
            out.writeln(
              '${broken.length} of ${items.length} fixtures break with the '
              'new spec:',
            );
            out.writeln(renderItems(broken, Reporter.text));
          }
        }
      case Reporter.json:
        out.writeln(
          const JsonEncoder.withIndent('  ').convert({
            ...diff.toJson(),
            if (configPath != null)
              'fixtures': {
                'checked': items.length,
                'broken': [
                  for (final item in broken)
                    {
                      'source': item.source,
                      'violations': [
                        for (final v in item.result.errors) v.toJson(),
                      ],
                    },
                ],
              },
          }),
        );
      case Reporter.github:
        for (final change in diff.changes) {
          out.writeln(switch (change.impact) {
            ChangeImpact.breaking => githubCommand(
              'error',
              '$change',
              title: 'Breaking API change',
            ),
            ChangeImpact.potentiallyBreaking => githubCommand(
              'warning',
              '$change',
              title: 'Potentially breaking API change',
            ),
            ChangeImpact.nonBreaking => githubCommand(
              'notice',
              '$change',
              title: 'API change',
            ),
          });
        }
        if (broken.isNotEmpty) {
          out.writeln(renderItems(broken, Reporter.github));
        }
      case Reporter.junit:
        throw UsageException(
          'The junit reporter is not supported here.',
          usage,
        );
    }

    return switch (stringOption('fail-on')) {
      'none' => 0,
      'potentially-breaking' =>
        diff.breaking.isNotEmpty ||
                diff.potentiallyBreaking.isNotEmpty ||
                broken.isNotEmpty
            ? exitFailure
            : 0,
      _ => diff.hasBreakingChanges || broken.isNotEmpty ? exitFailure : 0,
    };
  }
}

/// `coverage`: merges coverage files written by test runs.
final class CoverageCommand extends CliCommand {
  /// Creates the command.
  CoverageCommand(super.out, super.err) {
    argParser
      ..addOption(
        'min-operations',
        help: 'Minimum percentage of operations exercised.',
      )
      ..addOption(
        'min-responses',
        help: 'Minimum percentage of declared responses exercised.',
      )
      ..addOption('output', abbr: 'o', help: 'Write the merged JSON here.')
      ..addOption(
        'reporter',
        abbr: 'r',
        allowed: ['text', 'json', 'github'],
        defaultsTo: 'text',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'List fully covered operations too.',
      );
  }

  /// Where `api_validator_test` writes coverage files by default.
  static const defaultDirectory = 'build/api_validator/coverage';

  @override
  String get name => 'coverage';

  @override
  String get description =>
      'Merge API coverage files from test runs and enforce thresholds.';

  @override
  String get invocation =>
      '${runner!.executableName} coverage [<dir-or-file>...]';

  @override
  Future<int> run() async {
    final minOperations = _percent('min-operations');
    final minResponses = _percent('min-responses');
    final inputs = argResults!.rest.isEmpty
        ? const [defaultDirectory]
        : argResults!.rest;
    final files = <String>[];
    for (final input in inputs) {
      if (FileSystemEntity.isDirectorySync(input)) {
        files.addAll(
          [
            for (final entity in Directory(input).listSync(recursive: true))
              if (entity is File && entity.path.endsWith('.json')) entity.path,
          ]..sort(),
        );
      } else if (File(input).existsSync()) {
        files.add(input);
      } else {
        throw CliException('Coverage input not found: $input');
      }
    }
    if (files.isEmpty) {
      throw CliException(
        'No coverage files found in ${inputs.join(', ')}. Run your tests '
        'with api_validator_test first.',
      );
    }
    CoverageReport? merged;
    for (final file in files) {
      final CoverageReport report;
      try {
        report = CoverageReport.fromJson(
          jsonDecode(File(file).readAsStringSync()) as Map<String, Object?>,
        );
      } on Object catch (error) {
        throw CliException(
          'Invalid coverage file ${displayPath(file)}: $error',
        );
      }
      merged = merged == null ? report : merged.merge(report);
    }
    final report = merged!;

    final output = stringOption('output');
    if (output != null) {
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report.toJson()),
        );
    }

    final failures = <String>[];
    if (minOperations != null && report.operationRatio * 100 < minOperations) {
      failures.add(
        'Operation coverage ${_format(report.operationRatio)} is below '
        '$minOperations%.',
      );
    }
    if (minResponses != null && report.responseRatio * 100 < minResponses) {
      failures.add(
        'Response coverage ${_format(report.responseRatio)} is below '
        '$minResponses%.',
      );
    }

    switch (Reporter.parse(stringOption('reporter')!)) {
      case Reporter.text:
        out.write(report.toText(showAll: flag('all')));
        for (final failure in failures) {
          out.writeln(failure);
        }
      case Reporter.json:
        out.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({...report.toJson(), 'thresholdFailures': failures}),
        );
      case Reporter.github:
        for (final entry in report.untested) {
          out.writeln(
            githubCommand(
              'warning',
              '${entry.operation} is never called by the tests',
              title: 'Untested API operation',
            ),
          );
        }
        for (final failure in failures) {
          out.writeln(githubCommand('error', failure, title: 'API coverage'));
        }
        out.writeln(report.toText().split('\n').first);
      case Reporter.junit:
        throw UsageException(
          'The junit reporter is not supported here.',
          usage,
        );
    }
    if (output != null) out.writeln('Merged coverage written to $output');
    return failures.isEmpty ? 0 : exitFailure;
  }

  double? _percent(String option) {
    final value = stringOption(option);
    if (value == null) return null;
    final parsed = double.tryParse(value.replaceAll('%', ''));
    if (parsed == null || parsed < 0 || parsed > 100) {
      throw UsageException(
        '--$option must be a percentage between 0 and 100.',
        usage,
      );
    }
    return parsed;
  }
}

String _format(double ratio) => '${(ratio * 100).toStringAsFixed(1)}%';
