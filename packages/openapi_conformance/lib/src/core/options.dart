import 'package:meta/meta.dart';

import '../schema/schema_validator.dart';
import 'violation.dart';

/// How strictly an exchange is compared with the spec.
enum ConformanceMode {
  /// Undeclared properties, undeclared status codes and read-only/write-only
  /// misuse are errors.
  strict,

  /// Undeclared properties, undeclared status codes and read-only/write-only
  /// misuse are warnings. Everything else is still an error.
  lenient,
}

/// What to do with requests that match no operation in the spec.
enum UnmatchedPolicy {
  /// Report an error.
  error,

  /// Report a warning.
  warning,

  /// Ignore the request entirely.
  ignore,
}

/// Called for every violation found, for example to log it.
typedef ViolationCallback = void Function(Violation violation);

/// Settings for a `ConformanceChecker`.
@immutable
final class ConformanceOptions {
  /// Creates options. The defaults are suitable for tests.
  const ConformanceOptions({
    this.mode = ConformanceMode.strict,
    this.unmatchedRequests = UnmatchedPolicy.error,
    this.ignoreOperations = const [],
    this.ignorePaths = const [],
    this.validateRequests = true,
    this.validateResponses = true,
    this.validateFormats = true,
    this.checkSecurity = true,
    this.reportDeprecated = true,
    this.customFormats = const {},
    this.maxRecordedResults,
    this.onViolation,
    this.log = false,
  });

  /// Options suited to running inside an app in debug mode: lenient, unknown
  /// requests ignored, violations logged, and memory bounded.
  const ConformanceOptions.runtime({
    this.mode = ConformanceMode.lenient,
    this.unmatchedRequests = UnmatchedPolicy.ignore,
    this.ignoreOperations = const [],
    this.ignorePaths = const [],
    this.validateRequests = true,
    this.validateResponses = true,
    this.validateFormats = true,
    this.checkSecurity = false,
    this.reportDeprecated = true,
    this.customFormats = const {},
    this.maxRecordedResults = 200,
    this.onViolation,
    this.log = true,
  });

  /// Strict or lenient comparison.
  final ConformanceMode mode;

  /// Severity of requests that match no operation.
  final UnmatchedPolicy unmatchedRequests;

  /// Operations to skip, as `operationId` or `METHOD /path` references.
  final List<String> ignoreOperations;

  /// Request paths to skip entirely, for example `RegExp(r'^/health')`.
  final List<Pattern> ignorePaths;

  /// Whether requests (parameters, headers and body) are validated.
  final bool validateRequests;

  /// Whether responses (status, headers and body) are validated.
  final bool validateResponses;

  /// Whether string formats such as `date-time` and `uuid` are validated.
  final bool validateFormats;

  /// Whether a warning is reported when no security requirement of the
  /// operation is satisfied by the request headers, query or cookies.
  final bool checkSecurity;

  /// Whether a warning is reported when a deprecated operation is called.
  final bool reportDeprecated;

  /// Extra or overriding `format` validators keyed by format name.
  final Map<String, FormatValidator> customFormats;

  /// Keeps only the most recent results when set. Coverage is unaffected.
  final int? maxRecordedResults;

  /// Called for every violation found.
  final ViolationCallback? onViolation;

  /// Whether violations are written to the `dart:developer` log.
  final bool log;

  /// Severity used for findings that strict mode treats as errors.
  Severity get strictSeverity =>
      mode == ConformanceMode.strict ? Severity.error : Severity.warning;

  /// A copy of these options with the given fields replaced.
  ConformanceOptions copyWith({
    ConformanceMode? mode,
    UnmatchedPolicy? unmatchedRequests,
    List<String>? ignoreOperations,
    List<Pattern>? ignorePaths,
    bool? validateRequests,
    bool? validateResponses,
    bool? validateFormats,
    bool? checkSecurity,
    bool? reportDeprecated,
    Map<String, FormatValidator>? customFormats,
    int? maxRecordedResults,
    ViolationCallback? onViolation,
    bool? log,
  }) => ConformanceOptions(
    mode: mode ?? this.mode,
    unmatchedRequests: unmatchedRequests ?? this.unmatchedRequests,
    ignoreOperations: ignoreOperations ?? this.ignoreOperations,
    ignorePaths: ignorePaths ?? this.ignorePaths,
    validateRequests: validateRequests ?? this.validateRequests,
    validateResponses: validateResponses ?? this.validateResponses,
    validateFormats: validateFormats ?? this.validateFormats,
    checkSecurity: checkSecurity ?? this.checkSecurity,
    reportDeprecated: reportDeprecated ?? this.reportDeprecated,
    customFormats: customFormats ?? this.customFormats,
    maxRecordedResults: maxRecordedResults ?? this.maxRecordedResults,
    onViolation: onViolation ?? this.onViolation,
    log: log ?? this.log,
  );
}
