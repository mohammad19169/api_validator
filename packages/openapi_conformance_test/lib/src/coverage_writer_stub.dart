/// Files cannot be written on this platform; does nothing.
Future<String?> writeFile(String directory, String name, String contents) =>
    Future.value();
