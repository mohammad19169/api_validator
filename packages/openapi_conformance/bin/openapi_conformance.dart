import 'dart:io';

import 'package:openapi_conformance/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
