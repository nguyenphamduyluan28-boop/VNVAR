import 'package:camera_station/services/camera_station_runtime.dart';
import 'package:camera_station/services/cellular_uplink_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cellular fallback relay', () {
    test('uses protocol default ports and rejects unsupported schemes', () {
      expect(
        cellularTunnelEndpoint('rtmp://a.rtmp.youtube.com/live2/KEY'),
        (host: 'a.rtmp.youtube.com', port: 1935, tls: false),
      );
      expect(
        cellularTunnelEndpoint('rtmps://live-api-s.facebook.com/rtmp/KEY'),
        (host: 'live-api-s.facebook.com', port: 443, tls: true),
      );
      expect(
        cellularTunnelEndpoint('rtsp://10.0.0.2:18554/cam'),
        (host: '10.0.0.2', port: 18554, tls: false),
      );
      expect(cellularTunnelEndpoint('rtsps://example.com/live'), isNull);
    });

    test('RTMP keeps the original tcUrl for the streaming server', () {
      final target = buildCellularRelayTarget(
        'rtmp://a.rtmp.youtube.com/live2/abcd-1234',
        40123,
      );
      expect(target.url, 'rtmp://127.0.0.1:40123/live2/abcd-1234');
      expect(target.args, ['-rtmp_tcurl', 'rtmp://a.rtmp.youtube.com/live2']);
    });

    test('RTMPS is sent as plain RTMP to the local TLS relay', () {
      final target = buildCellularRelayTarget(
        'rtmps://live-api-s.facebook.com:443/rtmp/FB-KEY?s_bl=1',
        40124,
      );
      expect(target.url, 'rtmp://127.0.0.1:40124/rtmp/FB-KEY?s_bl=1');
      expect(target.args, [
        '-rtmp_tcurl',
        'rtmps://live-api-s.facebook.com:443/rtmp',
      ]);
    });
  });

  group('LAN address selection', () {
    test('ignores mobile data interfaces even with a private 10.x address', () {
      expect(
        selectStationLanAddress([
          (interface: 'rmnet_data0', address: '10.45.12.9'),
          (interface: 'ccmni1', address: '10.20.0.4'),
        ]),
        isNull,
      );
    });

    test('prefers Wi-Fi, then the phone hotspot', () {
      expect(
        selectStationLanAddress([
          (interface: 'rmnet_data0', address: '10.45.12.9'),
          (interface: 'ap0', address: '192.168.43.1'),
          (interface: 'wlan0', address: '192.168.1.20'),
        ]),
        '192.168.1.20',
      );
      expect(
        selectStationLanAddress([
          (interface: 'rmnet_data0', address: '10.45.12.9'),
          (interface: 'swlan0', address: '192.168.43.1'),
        ]),
        '192.168.43.1',
      );
    });

    test('classifies interface names', () {
      expect(lanInterfacePriority('wlan0'), 0);
      expect(lanInterfacePriority('eth0'), 0);
      expect(lanInterfacePriority('ap0'), 1);
      expect(lanInterfacePriority('rmnet_data1'), isNull);
      expect(lanInterfacePriority('ccmni0'), isNull);
      expect(lanInterfacePriority('seth_lte0'), isNull);
      expect(lanInterfacePriority('tun0'), isNull);
      expect(lanInterfacePriority('v4-rmnet_data0'), isNull);
    });
  });

  group('activeRouteLost', () {
    test('background mobile data changes do not affect a Wi-Fi stream', () {
      expect(
        activeRouteLost(
          {'rmnet_data0|10.1.2.3'},
          {'wlan0|192.168.1.20', 'rmnet_data0|10.1.9.9'},
        ),
        isFalse,
      );
      expect(
        activeRouteLost({'ap0|192.168.43.1'}, {'rmnet_data0|10.1.2.3'}),
        isFalse,
      );
    });

    test('losing Wi-Fi, or mobile data without Wi-Fi, breaks the route', () {
      expect(
        activeRouteLost({'wlan0|192.168.1.20'}, {'rmnet_data0|10.1.2.3'}),
        isTrue,
      );
      expect(
        activeRouteLost({'rmnet_data0|10.1.2.3'}, {'rmnet_data0|10.4.4.4'}),
        isTrue,
      );
    });
  });
}
