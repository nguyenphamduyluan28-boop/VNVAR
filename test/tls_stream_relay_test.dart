import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera_station/services/tls_stream_relay.dart';
import 'package:flutter_test/flutter_test.dart';

// Chứng chỉ tự ký CHỈ dùng cho test (máy chủ TLS giả trên 127.0.0.1), không
// phải bí mật và không dùng ở đâu khác.
const _testCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIULvtH8ekDFxIXsJraoNBT4GlpI4AwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTEwNTAyMTgxNFoYDzIxMjYx
MDEyMDIxODE0WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDQjZs/EetZw9/r0hQbqbWg+5Qz7b794ZMWI8qU4zkh
eokM7s2gUnkUxB9TsQ57HWU4V7ICfaFhkHuWsEbmJLp3Cay2z/sxmQF2nkchQtgI
5pdGqCiMn6OoHGMiOO7IVBJ6fQ3TGeME+3noJTuJosEws5IwRjAtJVoBHvCpkA/B
qbcb8Dme5Ilk9VdXqtXtaX7NYcrYd9mgpNSYBdvJB3TF4pInn5uZljbg0ptLf/W6
J9CZCrSUYNbS6bMhZoKQw0kXg5lxS+z46VtbBU39DS/RaoriucJTX6HN6501Ogol
nWxs3omarhiPokSrKEyMIv9ObeEwNRcyKmBMlDJFtVHHAgMBAAGjbzBtMB0GA1Ud
DgQWBBTBrgVM9Rn9lcVh4i7tMzqZp3YCvzAfBgNVHSMEGDAWgBTBrgVM9Rn9lcVh
4i7tMzqZp3YCvzAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEACFmJTitX/5j4FqWPw4U8N07oUhM2
0gDgCtHA5fq0Ab2Vg8epUUmnPtnfFQrw/3gFXS4OB6ozx3kc5AU7l1YFTonVJ4ri
vmuKcWqrzD1DujqlUiXH7Gkpoi38jJzX1v/ZfNdsORA5Bc/wAx/aJvQEmraShaOT
VJZihIhhOXVm7UqM1h+hDZGTSXPbAlyetIOP2DAuRPRlnXRqBz1mm0FIIfZeNn38
dv8OopYJ2YJP2ShRObKPrkIden9EI/vOR/6rU0e7c+GyijGZlgSyS9maF4XEbXf7
d4N9kgIVOjtUT2m0qo9KM7jQZH+yXmnTmOL3jBd2NjqOLgkbrGlLA4A9bw==
-----END CERTIFICATE-----
''';
const _testPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDQjZs/EetZw9/r
0hQbqbWg+5Qz7b794ZMWI8qU4zkheokM7s2gUnkUxB9TsQ57HWU4V7ICfaFhkHuW
sEbmJLp3Cay2z/sxmQF2nkchQtgI5pdGqCiMn6OoHGMiOO7IVBJ6fQ3TGeME+3no
JTuJosEws5IwRjAtJVoBHvCpkA/Bqbcb8Dme5Ilk9VdXqtXtaX7NYcrYd9mgpNSY
BdvJB3TF4pInn5uZljbg0ptLf/W6J9CZCrSUYNbS6bMhZoKQw0kXg5lxS+z46Vtb
BU39DS/RaoriucJTX6HN6501OgolnWxs3omarhiPokSrKEyMIv9ObeEwNRcyKmBM
lDJFtVHHAgMBAAECggEAIyAWi7La7s18w10oodgdjTWSKoTabCw397yjfBwhHTBk
MNdvrpb1abf2hsQFalrzF2A9zQmXyrTo++JIrq508WOhwVCaQCpDAtV5qXJ2rFka
FX5xBe5FRCUz1Sm9neP7EMJLN8jeYZJxX9YVhwLwguFbt+G6b4Ag/ptVcVmgLb+4
Dsv8Etes60cmTfnzra6TU0uzkw6otbDKI5W1a4Huh0ZA/onS7rw3Q2iIEn3oL6Ix
DH5Ektoe5bYQwjhfWtexDKU1YokwJyGxXm6lk8D6iE22wTkDikFm9zCr7jW0k1sP
B2EMAPnWU0kaupvqQLlKGM3xAZBQcDoVrNvBsmnDQQKBgQDpkF5D3zDrCfzTSkM1
qTWTRt4O5OvvSeW8y+eL9wgPE15CVeZjHHeADFmxAFECE5IwpgOrZyV3I0Vzm3xC
csLskyVVp6e/Rlg/AW7CJ64N9G0d0Te7PjBM/nhVx0l8DA7n8OANbr4SXRcZ3ilX
sTtYV9na0e2rmdUPZtX8ewOKkQKBgQDkljD+ord5XT321GQzmCd3Jd7Qh17tWIVN
CfQT9IX1vejSg69ClndPWnAFc6G9TEOB1FYZD5NfUaSP2w1T2V+XvkBAu28k7F3M
DeMU5Hr07r/w63o3nl7ZCnXxgOtvOqNKB2FA5AtQnqJn5ZCtxzOolaHaINWXRwIC
q4rxC4HS1wKBgQCIkRGNPgOsarqaEOIbjkT1SIquysvprpvWOKO7A0aDCiAjSXbc
nNiC1rXa+QRk4myoZWnf3v/ZGZaScmfFsrSm/6Lk4pMDFG6k6IGKpQjwv+rNdHfR
1BsJ6gESpuQg1CwjEoTvVcFtm2DWj0A9NjQtA7EucXE21UvvJYIZjxQTAQKBgQCB
aH3ISnowXRctW8R2aRc+ntPrnhehqtGccZwah/4mxyK9uwtHWUOmSv7MN1BDiJ9X
KsyrV2QJPIE7Z7m91HwHvg9GFlavwpi/YsVCGK97ZoaHb+g7AI+VtBRdaqzexYWX
7WGjiPbW51fuFcq4duPJ9xwwDxKcl/iNZmw8VlVi9QKBgHaLoMjXb5cBjSgW6Hsv
7iK+H1RN7R4/LNcGJZkIW5/B/xtAjTQeKkUFaGu/8aQ9O7EtgHfpv6wJ+nTiEPvH
/uEzhxLPRPDBxMpoT9CSDI8Kygza1C3NP3rOJFHVVPkQmL6MtoUXLaLGrteykA4W
kSmCz45HG3oklOwX8IYj7vQ5
-----END PRIVATE KEY-----
''';

void main() {
  test('rtmpsRelayEndpoint only handles rtmps:// URLs', () {
    expect(
      rtmpsRelayEndpoint('rtmps://live-api-s.facebook.com:443/rtmp/KEY'),
      (host: 'live-api-s.facebook.com', port: 443),
    );
    expect(
      rtmpsRelayEndpoint('rtmps://a.rtmps.youtube.com/live2/k'),
      (host: 'a.rtmps.youtube.com', port: 443),
    );
    expect(rtmpsRelayEndpoint('rtmp://a.rtmp.youtube.com/live2/k'), isNull);
    expect(rtmpsRelayEndpoint('rtmp://127.0.0.1:40124/rtmp/k'), isNull);
    expect(rtmpsRelayEndpoint('rtsp://host/live'), isNull);
  });

  test('relays plain TCP from FFmpeg to the TLS server and back', () async {
    final serverContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_testCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(_testPrivateKeyPem));
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    final received = Completer<String>();
    server.listen((client) {
      client.listen((data) {
        client.add(data); // Máy chủ giả: trả lại đúng dữ liệu nhận được.
        if (!received.isCompleted) received.complete(utf8.decode(data));
      });
    });
    final relay = await TlsStreamRelay.start(
      '127.0.0.1',
      server.port,
      onBadCertificate: (_) => true, // Chứng chỉ tự ký của test.
    );
    final local = await Socket.connect(
      InternetAddress.loopbackIPv4,
      relay.localPort,
    );
    final echoed = Completer<String>();
    local.listen((data) {
      if (!echoed.isCompleted) echoed.complete(utf8.decode(data));
    });
    local.add(utf8.encode('rtmp-handshake'));

    expect(
      await received.future.timeout(const Duration(seconds: 5)),
      'rtmp-handshake',
    );
    expect(
      await echoed.future.timeout(const Duration(seconds: 5)),
      'rtmp-handshake',
    );
    expect(relay.lastError, isNull);

    local.destroy();
    await relay.close();
    expect(relay.isClosed, isTrue);
    await server.close();
  });

  test('closes the FFmpeg side and records the error when the server is down',
      () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    final relay = await TlsStreamRelay.start(
      '127.0.0.1',
      port,
      connectTimeout: const Duration(seconds: 2),
    );
    final local = await Socket.connect(
      InternetAddress.loopbackIPv4,
      relay.localPort,
    );
    await local
        .handleError((Object _) {})
        .drain<void>()
        .timeout(const Duration(seconds: 5));
    expect(relay.lastError, isNotNull);
    await relay.close();
  });
}
