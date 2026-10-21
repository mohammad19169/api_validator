import 'dart:io';

import 'package:api_validator/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
