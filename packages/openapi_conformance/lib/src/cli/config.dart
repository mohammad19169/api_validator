import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core/options.dart';
import '../spec/openapi_spec.dart';
import 'support.dart';

/// Default configuration file name, looked up in the working directory.
const defaultConfigFile = 'openapi_conformance.yaml';

/// Whether a fixture is a request or a response body.
enum FixtureDirection {
  /// A request body.
  request,

  /// A response body.
  response,
}

/// A fixture file mapped to an operation.
final class FixtureSpec {
  /// Creates a fixture mapping.
  const FixtureSpec({
    required this.path,
    required this.operation,
    this.status,
    this.direction = FixtureDirection.response,
  });

  /// Path of the JSON file.
  final String path;

  /// `operationId` or `METHOD /path`.
  final String operation;

  /// Response status code, required for response fixtures.
  final int? status;

  /// Request or response body.
  final FixtureDirection direction;

  /// Parses a `--fixture <file>=<operation>:<status>` argument. Use
  /// `request` instead of a status for request bodies.
  static FixtureSpec parseArgument(String argument) {
    final equals = argument.indexOf('=');
    final colon = argument.lastIndexOf(':');
    if (equals <= 0 || colon <= equals + 1 || colon == argument.length - 1) {
      throw CliException(
        'Invalid --fixture "$argument". Expected '
        '<file>=<operation>:<status>, for example '
        'pet.json=getPet:200 or body.json=createPet:request.',
      );
    }
    final path = argument.substring(0, equals);
    final operation = argument.substring(equals + 1, colon).trim();
    final target = argument.substring(colon + 1).trim();
    if (target == 'request') {
      return FixtureSpec(
        path: path,
        operation: operation,
        direction: FixtureDirection.request,
      );
    }
    final status = int.tryParse(target);
    if (status == null) {
      throw CliException('Invalid status "$target" in --fixture "$argument".');
    }
    return FixtureSpec(path: path, operation: operation, status: status);
  }
}

/// The contents of an `openapi_conformance.yaml` file.
final class CliConfig {
  /// Creates a configuration.
  const CliConfig({
    this.specPath,
    this.mode,
    this.unmatched,
    this.fixtures = const [],
    this.har = const [],
  });

  /// Path of the spec, resolved against the config directory.
  final String? specPath;

  /// `mode:` value.
  final ConformanceMode? mode;

  /// `unmatched:` value.
  final UnmatchedPolicy? unmatched;

  /// Fixture mappings with globs expanded.
  final List<FixtureSpec> fixtures;

  /// HAR files.
  final List<String> har;

  /// Loads and validates the configuration at [path].
  static CliConfig load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw CliException('Config file not found: $path');
    }
    final Object? yaml;
    try {
      yaml = OpenApiSpec.toPlainJson(loadYaml(file.readAsStringSync()));
    } on YamlException catch (error) {
      throw CliException('Invalid config $path: ${error.message}');
    }
    if (yaml == null) return const CliConfig();
    if (yaml is! Map<String, Object?>) {
      throw CliException('Invalid config $path: the root must be a map.');
    }
    final directory = p.dirname(p.absolute(path));
    String resolve(String value) =>
        p.normalize(p.isAbsolute(value) ? value : p.join(directory, value));

    final spec = yaml['spec'];
    final fixtures = <FixtureSpec>[];
    final rawFixtures = yaml['fixtures'];
    if (rawFixtures != null && rawFixtures is! List<Object?>) {
      throw CliException('Invalid config $path: "fixtures" must be a list.');
    }
    for (final (index, entry)
        in ((rawFixtures as List<Object?>?) ?? const []).indexed) {
      if (entry is! Map<String, Object?>) {
        throw CliException(
          'Invalid config $path: fixtures[$index] must be a map.',
        );
      }
      final operation = entry['operation'];
      if (operation is! String || operation.trim().isEmpty) {
        throw CliException(
          'Invalid config $path: fixtures[$index] needs an "operation".',
        );
      }
      final direction = switch (entry['direction']) {
        null || 'response' => FixtureDirection.response,
        'request' => FixtureDirection.request,
        final other => throw CliException(
          'Invalid config $path: fixtures[$index].direction "$other" must be '
          'request or response.',
        ),
      };
      final rawStatus = entry['status'];
      final status = rawStatus is int
          ? rawStatus
          : int.tryParse('${rawStatus ?? ''}');
      if (direction == FixtureDirection.response && status == null) {
        throw CliException(
          'Invalid config $path: fixtures[$index] needs a "status" for a '
          'response fixture.',
        );
      }
      final List<String> files;
      if (entry['path'] is String) {
        files = [resolve(entry['path']! as String)];
      } else if (entry['glob'] is String) {
        final glob = Glob((entry['glob']! as String).replaceAll(r'\', '/'));
        files = [
          for (final entity in glob.listSync(root: directory))
            if (entity is File) p.normalize(entity.absolute.path),
        ]..sort();
        if (files.isEmpty) {
          throw CliException(
            'Invalid config $path: glob "${entry['glob']}" matched no files.',
          );
        }
      } else {
        throw CliException(
          'Invalid config $path: fixtures[$index] needs a "path" or "glob".',
        );
      }
      for (final file in files) {
        fixtures.add(
          FixtureSpec(
            path: file,
            operation: operation,
            status: status,
            direction: direction,
          ),
        );
      }
    }
    final rawHar = yaml['har'];
    final har = switch (rawHar) {
      null => const <String>[],
      final String single => [resolve(single)],
      final List<Object?> list => [for (final item in list) resolve('$item')],
      _ => throw CliException('Invalid config $path: "har" must be a list.'),
    };
    return CliConfig(
      specPath: spec is String ? resolve(spec) : null,
      mode: parseMode(yaml['mode'] as String?),
      unmatched: parseUnmatched(yaml['unmatched'] as String?),
      fixtures: fixtures,
      har: har,
    );
  }
}

/// Parses a `mode` value.
ConformanceMode? parseMode(String? value) => switch (value) {
  null => null,
  'strict' => ConformanceMode.strict,
  'lenient' => ConformanceMode.lenient,
  _ => throw CliException('Invalid mode "$value"; use strict or lenient.'),
};

/// Parses an `unmatched` value.
UnmatchedPolicy? parseUnmatched(String? value) => switch (value) {
  null => null,
  'error' => UnmatchedPolicy.error,
  'warning' => UnmatchedPolicy.warning,
  'ignore' => UnmatchedPolicy.ignore,
  _ => throw CliException(
    'Invalid unmatched policy "$value"; use error, warning or ignore.',
  ),
};
