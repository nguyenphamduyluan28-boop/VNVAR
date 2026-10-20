import 'dart:io';

import 'package:camera_station/services/camera_server.dart';
import 'package:camera_station/services/recording_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('giới hạn tần suất theo bucket', () {
    test('mọi alias Check VAR (mọi method) dùng bucket checkvar riêng', () {
      for (final path in checkVarRoutePaths) {
        for (final method in ['GET', 'POST']) {
          final limit = cameraServerRateLimitFor(path: path, method: method);
          expect(limit.bucket, 'checkvar', reason: '$method $path');
          expect(limit.maximum, 60);
        }
      }
    });

    test('ACK tải xong có bucket riêng, không tranh hạn mức control', () {
      final ack = cameraServerRateLimitFor(
        path: '/segments/CAM1_1700000000000/downloaded',
        method: 'POST',
      );
      expect(ack.bucket, 'ack');
      expect(ack.maximum, 600);
    });

    test('trim/stop vẫn thuộc bucket control 30/phút', () {
      for (final path in ['/trim', '/stop', '/video/trim', '/start']) {
        final limit = cameraServerRateLimitFor(path: path, method: 'POST');
        expect(limit.bucket, 'control', reason: path);
        expect(limit.maximum, 30);
      }
      expect(
        cameraServerRateLimitFor(path: '/segments', method: 'GET').bucket,
        'general',
      );
      expect(
        cameraServerRateLimitFor(path: '/checkvar/jobs/abc', method: 'GET')
            .bucket,
        'general',
      );
      expect(
        cameraServerRateLimitFor(path: '/api/score', method: 'POST').bucket,
        'scoreboard',
      );
    });
  });

  test('khoá phiên tải: X-Peer-ID nếu có, ngược lại IP client', () {
    expect(
      exportSessionOwner(peerId: 'tablet-1', remoteAddress: '10.0.0.2'),
      'peer:tablet-1',
    );
    expect(
      exportSessionOwner(peerId: '  ', remoteAddress: '10.0.0.2'),
      'ip:10.0.0.2',
    );
    expect(
      exportSessionOwner(peerId: null, remoteAddress: '10.0.0.3'),
      'ip:10.0.0.3',
    );
    expect(
      exportSessionOwner(peerId: 'a/b c', remoteAddress: '10.0.0.2'),
      'peer:a_b_c',
    );
  });

  group('lỗi Check VAR', () {
    test('không còn segment → NO_SEGMENT 409, không thử lại', () {
      final failure = classifyCheckVarFailure(
        const CheckVarSegmentUnavailableException('NO_SEGMENT', 'x'),
      );
      expect(failure.errorCode, 'NO_SEGMENT');
      expect(failure.httpStatus, HttpStatus.conflict);
      expect(failure.retryable, isFalse);
    });

    test('camera chưa ghi/đang treo ghi → NOT_RECORDING, thử lại được', () {
      final failure = classifyCheckVarFailure(
        const CheckVarSegmentUnavailableException('NOT_RECORDING', 'x'),
      );
      expect(failure.errorCode, 'NOT_RECORDING');
      expect(failure.httpStatus, HttpStatus.conflict);
      expect(failure.retryable, isTrue);
    });

    test('lỗi cắt clip và lỗi khác', () {
      expect(
        classifyCheckVarFailure(const InvalidTrimRangeException('x')),
        (
          errorCode: 'TRIM_FAILED',
          httpStatus: HttpStatus.unprocessableEntity,
          retryable: false,
        ),
      );
      expect(
        classifyCheckVarFailure(const TrimProcessingException('x')).errorCode,
        'TRIM_FAILED',
      );
      expect(
        classifyCheckVarFailure(const TrimSegmentNotFoundException('x'))
            .errorCode,
        'NO_SEGMENT',
      );
      final internal = classifyCheckVarFailure(StateError('boom'));
      expect(internal.errorCode, 'INTERNAL');
      expect(internal.httpStatus, HttpStatus.internalServerError);
      expect(internal.retryable, isTrue);
    });

    test('kết quả lỗi mang requestId và HTTP status khi phát lại', () {
      final result = checkVarFailureResult(
        requestId: 'req-1',
        requestedAt: DateTime(2026, 10, 20, 12),
        error: const CheckVarSegmentUnavailableException(
          'NO_SEGMENT',
          'Không còn segment',
        ),
        now: DateTime(2026, 10, 20, 12, 0, 1),
      );
      expect(result['success'], isFalse);
      expect(result['status'], 'FAILED');
      expect(result['requestId'], 'req-1');
      expect(result['errorCode'], 'NO_SEGMENT');
      expect(result['retryable'], isFalse);
      expect(result['message'], 'Không còn segment');
      expect(checkVarResponseStatus(result), HttpStatus.conflict);
      expect(checkVarResponseStatus({'status': 'READY'}), HttpStatus.ok);
    });
  });
}
