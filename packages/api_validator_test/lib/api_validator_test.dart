/// Test matchers and setup helpers for `package:api_validator`.
///
/// * [useApiValidator] fails each test whose HTTP traffic breaks the spec and
///   writes API coverage files.
/// * [isValid], [hasNoViolations], [hasViolation] and [exercised]
///   inspect a checker, a result or a list of violations.
/// * [conformsToResponse], [conformsToRequestBody] and [conformsToSchema]
///   check plain JSON values such as fixture files.
///
/// ```dart
/// void main() {
///   final spec = OpenApiSpec.fromFileSync('openapi.yaml');
///   final checker = useApiValidator(ApiValidator(spec));
///
///   test('fixture matches the spec', () {
///     expect(petFixture, conformsToResponse(spec, 'getPet'));
///   });
/// }
/// ```
library;

export 'package:api_validator/api_validator.dart';

export 'src/matchers.dart'
    show
        conformsToRequestBody,
        conformsToResponse,
        conformsToSchema,
        exercised,
        hasNoViolations,
        hasViolation,
        isValid;
export 'src/setup.dart'
    show
        defaultCoverageDirectory,
        describeValidationFailures,
        useApiValidator,
        useApiValidatorFromFile,
        writeCoverageReport;
