import 'dart:io';

import 'spec_exception.dart';

/// Reads the file at [path] as UTF-8 text.
Future<String> readText(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    throw OpenApiSpecException('Spec file not found: $path');
  }
  return file.readAsString();
}

/// Synchronously reads the file at [path] as UTF-8 text.
String readTextSync(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw OpenApiSpecException('Spec file not found: $path');
  }
  return file.readAsStringSync();
}
