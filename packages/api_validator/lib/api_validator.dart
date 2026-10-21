/// Validate HTTP traffic against an OpenAPI 3.0 or 3.1 spec.
///
/// The main entry point is [ApiValidator]. Feed it [Exchange]s, either
/// yourself or through an adapter package (`api_validator_dio`,
/// `api_validator_http`), then inspect [ApiValidator.violations]
/// and [ApiValidator.coverage].
///
/// ```dart
/// final checker = ApiValidator(OpenApiSpec.fromString(specYaml));
/// final result = checker.check(Exchange(
///   request: ExchangeRequest(
///     method: 'GET',
///     uri: Uri.parse('https://api.example.com/users/42'),
///   ),
///   response: ExchangeResponse(
///     statusCode: 200,
///     headers: {'content-type': 'application/json'},
///     body: '{"id": 42, "name": "Ada"}',
///   ),
/// ));
/// print(result.isValid);
/// ```
library;

export 'src/core/checker.dart'
    show ApiValidator, ApiValidationException, ValidationResult;
export 'src/core/exchange.dart'
    show Exchange, ExchangeRequest, ExchangeResponse;
export 'src/core/options.dart'
    show ValidationMode, ValidatorOptions, UnmatchedPolicy, ViolationCallback;
export 'src/core/violation.dart';
export 'src/coverage/coverage.dart'
    show CoverageReport, CoverageTracker, OperationCoverage;
export 'src/diff/spec_diff.dart' show ChangeImpact, SpecChange, SpecDiff;
export 'src/fake/edge_cases.dart' show EdgeCase, EdgeCases;
export 'src/fake/fake_data.dart' show FakeData;
export 'src/har/har.dart' show parseHar;
export 'src/report/reporters.dart' show ValidationReporter;
export 'src/routing/operation_matcher.dart'
    show
        OperationMatcher,
        RouteMatched,
        RouteMethodNotAllowed,
        RouteNotFound,
        RouteResult;
export 'src/schema/formats.dart' show builtInFormats;
export 'src/schema/schema_error.dart' show JsonPath, SchemaError;
export 'src/schema/schema_validator.dart'
    show FormatValidator, SchemaDirection, SchemaValidator;
export 'src/spec/media_type.dart' show MediaTypes;
export 'src/spec/openapi_spec.dart' show OpenApiSpec, OpenApiVersion;
export 'src/spec/operation.dart';
export 'src/spec/spec_exception.dart' show OpenApiSpecException;
