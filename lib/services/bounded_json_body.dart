import 'dart:convert';
import 'dart:typed_data';

/// Raised before an HTTP request body can consume unbounded memory.
class PayloadTooLargeException implements Exception {
  final int maximumBytes;

  const PayloadTooLargeException(this.maximumBytes);

  @override
  String toString() => 'Request body exceeds $maximumBytes bytes';
}

/// Incrementally collects and decodes one bounded JSON object.
class BoundedJsonBodyDecoder {
  final int maximumBytes;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _length = 0;

  BoundedJsonBodyDecoder({required this.maximumBytes})
    : assert(maximumBytes > 0);

  void add(List<int> chunk) {
    _length += chunk.length;
    if (_length > maximumBytes) {
      throw PayloadTooLargeException(maximumBytes);
    }
    _bytes.add(chunk);
  }

  Map<String, dynamic> decode() {
    final body = utf8.decode(_bytes.takeBytes());
    if (body.trim().isEmpty) return <String, dynamic>{};

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be object');
    }
    return decoded;
  }
}
