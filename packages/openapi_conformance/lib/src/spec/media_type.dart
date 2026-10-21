/// Helpers for working with media types such as `application/json`.
abstract final class MediaTypes {
  /// Returns the media type without parameters, lower-cased.
  ///
  /// `application/JSON; charset=utf-8` becomes `application/json`.
  static String essence(String mediaType) =>
      mediaType.split(';').first.trim().toLowerCase();

  /// Whether [mediaType] is JSON (`application/json` or any `+json` suffix).
  static bool isJson(String? mediaType) {
    if (mediaType == null) return false;
    final value = essence(mediaType);
    return value == 'application/json' ||
        value.endsWith('+json') ||
        value == 'text/json';
  }

  /// Selects the key of [content] that best describes [actual].
  ///
  /// Exact matches win, then `type/*`, then `*/*`. When [actual] is `null`
  /// and [content] has exactly one entry, that entry is returned.
  static String? select(Iterable<String> content, String? actual) {
    final keys = content.toList();
    if (keys.isEmpty) return null;
    if (actual == null || actual.trim().isEmpty) {
      return keys.length == 1 ? keys.single : _firstJson(keys);
    }
    final target = essence(actual);
    for (final key in keys) {
      if (essence(key) == target) return key;
    }
    final type = target.split('/').first;
    for (final key in keys) {
      if (essence(key) == '$type/*') return key;
    }
    for (final key in keys) {
      if (essence(key) == '*/*') return key;
    }
    return null;
  }

  static String? _firstJson(List<String> keys) {
    for (final key in keys) {
      if (isJson(key)) return key;
    }
    return null;
  }
}
