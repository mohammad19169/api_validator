/// Test matchers and setup helpers for `package:openapi_conformance`.
///
/// * [useConformance] fails each test whose HTTP traffic breaks the spec and
///   writes API coverage files.
/// * [isConforming], [hasNoViolations], [hasViolation] and [exercised]
///   inspect a checker, a result or a list of violations.
/// * [conformsToResponse], [conformsToRequestBody] and [conformsToSchema]
///   check plain JSON values such as fixture files.
///
/// ```dart
/// void main() {
///   final spec = OpenApiSpec.fromFileSync('openapi.yaml');
///   final checker = useConformance(ConformanceChecker(spec));
///
///   test('fixture matches the spec', () {
///     expect(petFixture, conformsToResponse(spec, 'getPet'));
///   });
/// }
/// ```
library;

export 'package:openapi_conformance/openapi_conformance.dart';

export 'src/matchers.dart'
    show
        conformsToRequestBody,
        conformsToResponse,
        conformsToSchema,
        exercised,
        hasNoViolations,
        hasViolation,
        isConforming;
export 'src/setup.dart'
    show
        defaultCoverageDirectory,
        describeConformanceFailures,
        useConformance,
        useConformanceFromFile,
        writeCoverageReport;
