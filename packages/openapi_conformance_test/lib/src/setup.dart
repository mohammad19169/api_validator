import 'dart:convert';
import 'dart:math';

import 'package:matcher/expect.dart' show fail;
import 'package:openapi_conformance/openapi_conformance.dart';
import 'package:test_api/scaffolding.dart';

import 'coverage_writer_stub.dart'
    if (dart.library.io) 'coverage_writer_io.dart'
    as writer;

/// The directory [useConformance] writes coverage files to by default.
const defaultCoverageDirectory = 'build/openapi_conformance/coverage';

/// Wires [checker] into the current test suite and returns it.
///
/// Call it at the top of `main()` (or inside a `group`). It registers:
///
/// * a `setUp` that clears recorded results (coverage is kept),
/// * a `tearDown` that fails the test when errors (and, with
///   [failOnWarnings], warnings) were recorded during it,
/// * a `tearDownAll` that writes the coverage of the suite as JSON into
///   [coverageDirectory] (pass `null` to skip). Merge the files of all test
///   suites with `dart run openapi_conformance coverage`.
///
/// ```dart
/// void main() {
///   final checker = useConformance(ConformanceChecker(spec));
///   final dio = Dio()..addConformance(checker);
///
///   test('loads a pet', () async {
///     await PetRepository(dio).load(1); // fails if the traffic breaks the spec
///   });
/// }
/// ```
ConformanceChecker useConformance(
  ConformanceChecker checker, {
  bool failOnErrors = true,
  bool failOnWarnings = false,
  String? coverageDirectory = defaultCoverageDirectory,
}) {
  setUp(checker.reset);
  tearDown(() {
    final message = describeConformanceFailures(
      checker,
      failOnErrors: failOnErrors,
      failOnWarnings: failOnWarnings,
    );
    if (message != null) fail(message);
  });
  if (coverageDirectory != null) {
    tearDownAll(() => writeCoverageReport(checker.coverage, coverageDirectory));
  }
  return checker;
}

/// Loads the spec at [specPath] synchronously and calls [useConformance]
/// with a new [ConformanceChecker].
///
/// Needs `dart:io`, so it works in VM and Flutter tests but not in browser
/// tests.
ConformanceChecker useConformanceFromFile(
  String specPath, {
  ConformanceOptions options = const ConformanceOptions(),
  bool failOnErrors = true,
  bool failOnWarnings = false,
  String? coverageDirectory = defaultCoverageDirectory,
}) => useConformance(
  ConformanceChecker(OpenApiSpec.fromFileSync(specPath), options: options),
  failOnErrors: failOnErrors,
  failOnWarnings: failOnWarnings,
  coverageDirectory: coverageDirectory,
);

/// Returns a readable failure message for the violations recorded by
/// [checker], or `null` when nothing should fail.
///
/// This is what the `tearDown` registered by [useConformance] uses.
String? describeConformanceFailures(
  ConformanceChecker checker, {
  bool failOnErrors = true,
  bool failOnWarnings = false,
}) {
  final failing = [
    for (final violation in checker.violations)
      if ((violation.isError && failOnErrors) ||
          (!violation.isError && failOnWarnings))
        violation,
  ];
  if (failing.isEmpty) return null;
  final failingResults = [
    for (final result in checker.results)
      if (result.violations.any(failing.contains)) result,
  ];
  final count = failing.length;
  return [
    'The HTTP traffic of this test does not match the OpenAPI spec '
        '($count violation${count == 1 ? '' : 's'}):',
    for (final result in failingResults) '$result',
  ].join('\n');
}

final _random = Random();

/// Writes [report] as JSON into [directory] under a unique file name and
/// returns the file path.
///
/// Returns `null` where files cannot be written (for example in browser
/// tests).
Future<String?> writeCoverageReport(
  CoverageReport report, [
  String directory = defaultCoverageDirectory,
]) {
  final name =
      'coverage-${DateTime.now().microsecondsSinceEpoch}-'
      '${_random.nextInt(0x3fffffff).toRadixString(16)}.json';
  return writer.writeFile(
    directory,
    name,
    const JsonEncoder.withIndent('  ').convert(report.toJson()),
  );
}
