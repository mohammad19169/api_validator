import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands.dart';
import 'fake_command.dart';
import 'support.dart';

/// Runs the `openapi_conformance` command line tool and returns its exit
/// code: 0 on success, 1 on conformance failures, 2 on usage errors.
Future<int> runCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final runner = _Runner(stdoutSink);
  for (final command in buildCommands(stdoutSink, stderrSink)) {
    runner.addCommand(command);
  }
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (error) {
    stderrSink
      ..writeln(error.message)
      ..writeln()
      ..writeln(error.usage);
    return exitUsage;
  } on CliException catch (error) {
    stderrSink.writeln('Error: ${error.message}');
    return exitUsage;
  }
}

/// The commands of the tool.
List<CliCommand> buildCommands(StringSink out, StringSink err) => [
  CheckCommand(out, err),
  DiffCommand(out, err),
  CoverageCommand(out, err),
  FakeCommand(out, err),
];

final class _Runner extends CommandRunner<int> {
  _Runner(this._out)
    : super(
        'openapi_conformance',
        'Check JSON fixtures, HAR recordings, API coverage and spec changes '
            'against an OpenAPI 3.0/3.1 spec.',
      );

  final StringSink _out;

  @override
  void printUsage() => _out.writeln(usage);
}
