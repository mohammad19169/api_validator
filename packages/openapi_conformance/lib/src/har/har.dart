import 'dart:convert';
import 'dart:typed_data';

import '../core/exchange.dart';

/// Parses a HAR 1.2 archive (as exported by browser dev tools, Charles,
/// Proxyman or mitmproxy) into exchanges that a `ConformanceChecker` can
/// check.
///
/// Entries without a response (status `0`) are skipped. Base64 encoded
/// response bodies become `Uint8List`s.
///
/// Throws a [FormatException] when [json] is not a HAR document.
List<Exchange> parseHar(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (error) {
    throw FormatException('Not a HAR file: ${error.message}');
  }
  final log = decoded is Map<String, Object?> ? decoded['log'] : null;
  final entries = log is Map<String, Object?> ? log['entries'] : null;
  if (entries is! List<Object?>) {
    throw const FormatException('Not a HAR file: missing "log.entries".');
  }
  final exchanges = <Exchange>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry is! Map<String, Object?>) continue;
    final request = entry['request'];
    final response = entry['response'];
    if (request is! Map<String, Object?> || response is! Map<String, Object?>) {
      continue;
    }
    final status = response['status'];
    if (status is! num || status == 0) continue;
    final url = request['url'];
    final method = request['method'];
    if (url is! String || method is! String) {
      throw FormatException('HAR entry $i has no request method or url.');
    }
    final requestHeaders = _headers(request['headers']);
    final postData = request['postData'];
    Object? requestBody;
    if (postData is Map<String, Object?>) {
      final text = postData['text'];
      final params = postData['params'];
      if (text is String && text.isNotEmpty) {
        requestBody = text;
      } else if (params is List<Object?> && params.isNotEmpty) {
        requestBody = [
          for (final param in params)
            if (param is Map<String, Object?>)
              '${Uri.encodeQueryComponent('${param['name']}')}='
                  '${Uri.encodeQueryComponent('${param['value'] ?? ''}')}',
        ].join('&');
      }
      final mimeType = postData['mimeType'];
      if (mimeType is String &&
          mimeType.isNotEmpty &&
          !requestHeaders.keys.any((k) => k.toLowerCase() == 'content-type')) {
        requestHeaders['content-type'] = mimeType;
      }
    }
    final responseHeaders = _headers(response['headers']);
    final content = response['content'];
    Object? responseBody;
    if (content is Map<String, Object?>) {
      final text = content['text'];
      if (text is String && text.isNotEmpty) {
        responseBody = content['encoding'] == 'base64'
            ? Uint8List.fromList(base64Decode(text))
            : text;
      }
      final mimeType = content['mimeType'];
      if (mimeType is String &&
          mimeType.isNotEmpty &&
          !responseHeaders.keys.any((k) => k.toLowerCase() == 'content-type')) {
        responseHeaders['content-type'] = mimeType;
      }
    }
    exchanges.add(
      Exchange(
        request: ExchangeRequest(
          method: method,
          uri: Uri.parse(url),
          headers: requestHeaders,
          body: requestBody,
        ),
        response: ExchangeResponse(
          statusCode: status.toInt(),
          headers: responseHeaders,
          body: responseBody,
        ),
      ),
    );
  }
  return exchanges;
}

Map<String, String> _headers(Object? raw) {
  final result = <String, String>{};
  if (raw is! List<Object?>) return result;
  for (final header in raw) {
    if (header is! Map<String, Object?>) continue;
    final name = header['name'];
    final value = header['value'];
    if (name is! String || name.startsWith(':')) continue;
    final text = '${value ?? ''}';
    final existing = result[name];
    result[name] = existing == null ? text : '$existing, $text';
  }
  return result;
}
