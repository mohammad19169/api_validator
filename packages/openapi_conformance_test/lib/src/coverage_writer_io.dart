import 'dart:io';

/// Writes [contents] to [name] inside [directory], creating it if needed.
Future<String?> writeFile(
  String directory,
  String name,
  String contents,
) async {
  final folder = await Directory(directory).create(recursive: true);
  final file = File('${folder.path}${Platform.pathSeparator}$name');
  await file.writeAsString(contents);
  return file.path;
}
