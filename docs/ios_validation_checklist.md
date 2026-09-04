# VNVAR Camera Station — iOS validation checklist

## 6. CocoaPods

Run on macOS from the project root:

```bash
flutter clean
flutter pub get
cd ios
pod deintegrate
pod install --repo-update
cd ..
```

Pass criteria:

- `pod install` exits with code 0.
- `ios/Podfile.lock` is generated, reviewed and committed so CI/release machines
  resolve the same native dependencies. Do not create this file manually.
- `ios/Runner.xcworkspace` opens without missing pod references.
- All pods use an iOS deployment target of at least 14.0.

## 7. Build on macOS

```bash
flutter doctor -v
flutter analyze
flutter test
flutter build ios --debug --no-codesign
```

Then configure Team, Bundle Identifier and automatic signing in Xcode and run:

```bash
flutter build ipa --release
```

Pass criteria: no Dart, CocoaPods, signing or linker errors.

## 8. Real iPhone camera test

1. Install from Xcode on a physical iPhone.
2. Accept Camera and Local Network permissions.
3. Start CAM-01 and verify the local preview for 10 minutes.
4. Switch front/back cameras at least five times.
5. Lock the screen and background the app to confirm the documented iOS
   limitation: continuous camera recording is only guaranteed in foreground.

Pass criteria: no crash, frozen preview, duplicate capture or hidden camera
session after returning to the app.

## 9. WebRTC iPhone ↔ Tablet

1. Put both devices on the same Wi-Fi network.
2. Verify discovery and `GET /status`.
3. Open `/viewer` and the Tablet WebRTC client.
4. Disconnect/reconnect Wi-Fi and repeat three times.
5. Confirm `rtspSupported: true`, `rtspRunning: true` and connect CheckVAR to
   `rtsp://<iphone-ip>:8554/camera`.
6. Keep WebRTC connected while RTSP is playing and verify neither transport
   restarts the shared camera track.

Pass criteria: live video appears, reconnects without restarting the app and
latency does not continuously increase.

## 10. Segment and CHECKVAR

1. Record longer than one configured segment interval.
2. Confirm completed files use `HH-mm-ss_HH-mm-ss.ts`.
3. Call `POST /checkvar` halfway through a segment.
4. Verify the response includes a valid `checkpointSegment.downloadUrl`.
5. Play/download the checkpoint and confirm the next segment continues.

Pass criteria: no missing segment, zero-byte file, overlapping rotation or
`PathNotFoundException`.

## 11. Long-duration test

Run in foreground for at least 6 hours while recording:

- Check `/status` every 60 seconds.
- Call CHECKVAR periodically.
- Monitor storage, temperature and memory in Xcode Instruments.
- Verify five-minute protection for newly completed files.
- Verify rolling cleanup and day rollover with a controlled test clock/build.

Pass criteria: recording continues, storage stays bounded, newest segments are
retained and memory usage does not grow continuously.

## 12. RTSP native iOS

1. Connect and disconnect the actual CheckVAR RTSP consumer at least 20 times.
2. Verify PLAY begins on an IDR frame and no green/yellow macroblocks appear.
3. Simulate weak Wi-Fi and verify slow clients are removed without stopping
   recording or WebRTC.
4. Verify RTCP Sender Report is emitted and CheckVAR Receiver Report changes
   the native encoder bitrate.
5. Force decoder recovery and verify PLI requests a new keyframe.
6. Test one through four simultaneous RTSP clients; a fifth client must be
   rejected without affecting existing viewers.

Pass criteria: RTSP, WebRTC and recording share one capture track, reconnects
do not crash Network.framework, latency remains bounded and saved video keeps
recording throughout the test.
