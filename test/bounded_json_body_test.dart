import 'dart:convert';

import 'package:camera_station/services/bounded_json_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoundedJsonBodyDecoder', () {
    test('decodes an object split across chunks', () {
      final decoder = BoundedJsonBodyDecoder(maximumBytes: 64);
      decoder.add(utf8.encode('{"camera"'));
      decoder.add(utf8.encode(':"CAM-01"}'));

      expect(decoder.decode(), {'camera': 'CAM-01'});
    });

    test('returns an empty object for an empty body', () {
      final decoder = BoundedJsonBodyDecoder(maximumBytes: 16);

      expect(decoder.decode(), isEmpty);
    });

    test('rejects a body as soon as it exceeds the byte limit', () {
      final decoder = BoundedJsonBodyDecoder(maximumBytes: 4);
      decoder.add([1, 2, 3]);

      expect(
        () => decoder.add([4, 5]),
        throwsA(isA<PayloadTooLargeException>()),
      );
    });

    test('rejects a JSON value that is not an object', () {
      final decoder = BoundedJsonBodyDecoder(maximumBytes: 16);
      decoder.add(utf8.encode('[1,2]'));

      expect(decoder.decode, throwsFormatException);
    });
  });
}
