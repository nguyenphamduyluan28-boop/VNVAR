import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera_station/services/discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kết nối discovery TCP: client im lặng quá hạn bị đóng hẳn (không giữ
/// subscription/socket), client hợp lệ vẫn nhận phản hồi như cũ.
void main() {
  late ServerSocket server;
  late StreamIterator<Socket> accepted;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    accepted = StreamIterator<Socket>(server);
  });

  tearDown(() async {
    await accepted.cancel();
    await server.close();
  });

  Future<(Socket client, Socket serverSide)> connect() async {
    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    expect(await accepted.moveNext(), isTrue);
    return (client, accepted.current);
  }

  test('client im lặng: đóng kết nối sau timeout', () async {
    final service = DiscoveryService(
      clientTimeout: const Duration(milliseconds: 200),
    );
    final (client, serverSide) = await connect();
    final received = <int>[];
    final closed = Completer<void>();
    client.listen(
      received.addAll,
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );

    await service
        .debugHandleClient(serverSide)
        .timeout(const Duration(seconds: 5));
    await closed.future.timeout(const Duration(seconds: 5));

    expect(received, isEmpty);
    client.destroy();
  });

  test('client gửi lệnh discovery: nhận phản hồi JSON', () async {
    final service = DiscoveryService();
    final (client, serverSide) = await connect();
    final handled = service.debugHandleClient(serverSide);
    client.writeln(DiscoveryService.discoverMessage);
    await client.flush();

    final response = await utf8.decoder
        .bind(client)
        .join()
        .timeout(const Duration(seconds: 5));
    await handled.timeout(const Duration(seconds: 5));

    final decoded = jsonDecode(response.trim()) as Map<String, dynamic>;
    expect(decoded['type'], DiscoveryService.responseType);
    expect(decoded['transport'], 'TCP');
    client.destroy();
  });

  test('đóng kết nối không bao giờ ném lỗi', () async {
    final (client, serverSide) = await connect();
    serverSide.destroy();
    await closeDiscoveryClient(serverSide, graceful: true);
    await closeDiscoveryClient(serverSide, graceful: false);
    client.destroy();
  });
}
