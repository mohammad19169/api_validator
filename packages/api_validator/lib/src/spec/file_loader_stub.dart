/// Reading files requires `dart:io`, which this platform lacks.
Future<String> readText(String path) =>
    Future.error(UnsupportedError(_message));

/// Reading files requires `dart:io`, which this platform lacks.
String readTextSync(String path) => throw UnsupportedError(_message);

const _message =
    'Loading a spec from a file needs dart:io. On the web, fetch the document '
    'yourself and call OpenApiSpec.fromString.';
