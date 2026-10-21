import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../fake/edge_cases.dart';
import '../fake/fake_data.dart';
import '../schema/schema_validator.dart';
import 'config.dart';
import 'support.dart';

/// `fake`: prints schema-valid fake data or edge cases as JSON.
final class FakeCommand extends CliCommand {
  /// Creates the command.
  FakeCommand(super.out, super.err) {
    argParser
      ..addOption(
        'spec',
        abbr: 's',
        help:
            'OpenAPI spec (JSON or YAML). Defaults to the spec of '
            'openapi_conformance.yaml.',
      )
      ..addOption('status', help: 'Response status code (default: first 2xx).')
      ..addFlag(
        'request',
        negatable: false,
        help: 'Generate the request body instead of the response body.',
      )
      ..addOption('component', help: 'Generate a components.schemas entry.')
      ..addOption('seed', help: 'Random seed for reproducible output.')
      ..addFlag(
        'edge-cases',
        negatable: false,
        help: 'Print edge-case variants instead of one value.',
      );
  }

  @override
  String get name => 'fake';

  @override
  String get description =>
      'Print schema-valid fake data (or edge cases) for an operation.';

  @override
  String get invocation =>
      '${runner!.executableName} fake [options] <operationId | "METHOD /path">';

  @override
  Future<int> run() async {
    final spec = loadSpec(_specPath());
    final rest = argResults!.rest;
    final component = stringOption('component');
    if (component == null && rest.length != 1) {
      throw UsageException(
        'Expected one operation, or --component <name>.',
        usage,
      );
    }
    final seed = _intOption('seed');
    final status = _intOption('status');
    final request = flag('request');
    const encoder = JsonEncoder.withIndent('  ');

    try {
      if (flag('edge-cases')) {
        final generator = EdgeCases(spec, seed: seed);
        final cases = component != null
            ? generator.forComponent(component)
            : request
            ? generator.forRequestBody(rest.single)
            : generator.forResponse(rest.single, status: status);
        out.writeln(
          encoder.convert([
            for (final edge in cases)
              {
                'description': edge.description,
                'path': edge.path,
                'conformsToSpec': edge.conformsToSpec,
                'value': edge.value,
              },
          ]),
        );
        return exitSuccess;
      }
      final fake = FakeData(spec, seed: seed);
      final value = component != null
          ? fake.component(
              component,
              direction: request
                  ? SchemaDirection.request
                  : SchemaDirection.response,
            )
          : request
          ? fake.requestBody(rest.single)
          : fake.response(rest.single, status: status);
      out.writeln(encoder.convert(value));
      return exitSuccess;
    } on ArgumentError catch (error) {
      throw CliException('${error.message}');
    }
  }

  String _specPath() {
    final explicit = stringOption('spec');
    if (explicit != null) return explicit;
    if (File('openapi_conformance.yaml').existsSync()) {
      final configured = CliConfig.load('openapi_conformance.yaml').specPath;
      if (configured != null) return configured;
    }
    throw UsageException('Missing --spec.', usage);
  }

  int? _intOption(String name) {
    final raw = stringOption(name);
    if (raw == null) return null;
    return int.tryParse(raw) ??
        (throw UsageException('--$name must be an integer.', usage));
  }
}
