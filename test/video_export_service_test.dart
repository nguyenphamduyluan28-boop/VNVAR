import 'dart:async';
import 'dart:io';

import 'package:camera_station/services/station_errors.dart';
import 'package:camera_station/services/video_export_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('needsRemux', () {
    test('MPEG-TS and unknown extensions need a remux', () {
      expect(VideoExportService.needsRemux('/v/VNVAR_CAM-01_1.ts'), isTrue);
      expect(VideoExportService.needsRemux('/v/VNVAR_CAM-01_1.TS'), isTrue);
      expect(VideoExportService.needsRemux('/v/clip.mkv'), isTrue);
      expect(VideoExportService.needsRemux('/v.dir/noextension'), isTrue);
    });

    test('MP4 and MOV are saved as-is', () {
      expect(VideoExportService.needsRemux('/v/CLIP_CAM1_1.mp4'), isFalse);
      expect(VideoExportService.needsRemux('/v/CLIP_CAM1_1.MP4'), isFalse);
      expect(VideoExportService.needsRemux('/v/a.mov'), isFalse);
    });
  });

  group('galleryFileName', () {
    test('keeps the original name with an .mp4 extension', () {
      expect(
        VideoExportService.galleryFileName('/a/b/VNVAR_CAM-01_1756000000000.ts'),
        'VNVAR_CAM-01_1756000000000.mp4',
      );
      expect(
        VideoExportService.galleryFileName(r'C:\v\CLIP_CAM1_1.mp4'),
        'CLIP_CAM1_1.mp4',
      );
      expect(VideoExportService.galleryFileName('/a/b.c/x.MOV'), 'x.mov');
    });

    test('replaces unsafe characters and never returns an empty name', () {
      expect(VideoExportService.galleryFileName('/a/b:c?.ts'), 'b_c_.mp4');
      expect(VideoExportService.galleryFileName('/a/'), 'video.mp4');
      expect(VideoExportService.galleryFileName('/a/...ts'), 'video.mp4');
    });
  });

  group('saveToGallery', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('video_export_test');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<File> createVideo(String name) async {
      final file = File('${root.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(const [1, 2, 3, 4]);
      return file;
    }

    test('saves MP4 directly with display name and album', () async {
      final video = await createVideo('CLIP_CAM1_1.mp4');
      final calls = <Map<String, Object?>>[];
      var remuxCalls = 0;
      final service = VideoExportService(
        invokeNative: (method, arguments) async {
          expect(method, 'saveVideoToGallery');
          calls.add(arguments);
          return true;
        },
        remux: (_) async {
          remuxCalls++;
          return true;
        },
      );
      await service.saveToGallery(video.path);
      expect(remuxCalls, 0);
      expect(calls, hasLength(1));
      expect(calls.single['path'], video.path);
      expect(calls.single['displayName'], 'CLIP_CAM1_1.mp4');
      expect(calls.single['album'], 'SportO Cam');
    });

    test('remuxes .ts to a temporary MP4 and deletes it afterwards', () async {
      final video = await createVideo('VNVAR_CAM-01_1.ts');
      final tempRoot = Directory('${root.path}${Platform.pathSeparator}tmp');
      final remuxArguments = <List<String>>[];
      String? savedPath;
      final service = VideoExportService(
        temporaryDirectory: () async => tempRoot,
        remux: (arguments) async {
          remuxArguments.add(arguments);
          // Lần đầu (copy) giả lập lỗi; lần hai (AAC) thành công.
          if (remuxArguments.length == 1) return false;
          await File(arguments.last).writeAsBytes(const [9, 9]);
          return true;
        },
        invokeNative: (method, arguments) async {
          savedPath = arguments['path'] as String?;
          expect(arguments['displayName'], 'VNVAR_CAM-01_1.mp4');
          expect(await File(savedPath!).exists(), isTrue);
          return true;
        },
      );
      await service.saveToGallery(video.path);
      expect(remuxArguments, hasLength(2));
      expect(remuxArguments.first, containsAllInOrder(['-c', 'copy']));
      expect(remuxArguments.last, containsAllInOrder(['-c:a', 'aac']));
      expect(savedPath, isNotNull);
      expect(savedPath!.endsWith('.mp4'), isTrue);
      expect(savedPath!.startsWith(tempRoot.path), isTrue);
      expect(await File(savedPath!).exists(), isFalse);
      expect(await video.exists(), isTrue);
    });

    test('fails with convertFailed when every remux attempt fails', () async {
      final video = await createVideo('VNVAR_CAM-01_2.ts');
      var nativeCalls = 0;
      final service = VideoExportService(
        temporaryDirectory: () async => root,
        remux: (_) async => false,
        invokeNative: (_, _) async {
          nativeCalls++;
          return true;
        },
      );
      await expectLater(
        service.saveToGallery(video.path),
        throwsA(
          isA<VideoExportException>().having(
            (error) => error.code,
            'code',
            VideoExportErrorCode.convertFailed,
          ),
        ),
      );
      expect(nativeCalls, 0);
    });

    test('concurrent saves of the same file share one native call', () async {
      final video = await createVideo('CLIP_CAM2_1.mp4');
      final pending = Completer<Object?>();
      var nativeCalls = 0;
      final service = VideoExportService(
        invokeNative: (_, _) {
          nativeCalls++;
          return pending.future;
        },
      );
      final first = service.saveToGallery(video.path);
      final second = service.saveToGallery(video.path);
      expect(identical(first, second), isTrue);
      expect(service.isSaving(video.path), isTrue);
      pending.complete(true);
      await Future.wait([first, second]);
      expect(nativeCalls, 1);
      await Future<void>.delayed(Duration.zero);
      expect(service.isSaving(video.path), isFalse);
    });

    test('a finished save can run again for the same file', () async {
      final video = await createVideo('CLIP_CAM3_1.mp4');
      var nativeCalls = 0;
      final service = VideoExportService(
        invokeNative: (_, _) async {
          nativeCalls++;
          return true;
        },
      );
      await service.saveToGallery(video.path);
      await Future<void>.delayed(Duration.zero);
      await service.saveToGallery(video.path);
      expect(nativeCalls, 2);
    });

    test('maps PERMISSION_DENIED to a bilingual permission error', () async {
      final video = await createVideo('CLIP_CAM1_2.mp4');
      final service = VideoExportService(
        invokeNative: (_, _) async =>
            throw PlatformException(code: 'PERMISSION_DENIED'),
      );
      try {
        await service.saveToGallery(video.path);
        fail('expected VideoExportException');
      } on VideoExportException catch (error) {
        expect(error.isPermissionDenied, isTrue);
        expect(error, isA<BilingualMessage>());
        expect(error.localized(english: true), contains(galleryNameEn()));
        expect(error.localized(english: false), contains(galleryNameVi()));
      }
      // Lỗi không để lại khoá chạy trùng.
      await Future<void>.delayed(Duration.zero);
      expect(service.isSaving(video.path), isFalse);
    });

    test('maps SAVE_FAILED and false results to saveFailed', () async {
      final video = await createVideo('CLIP_CAM1_3.mp4');
      final failing = VideoExportService(
        invokeNative: (_, _) async =>
            throw PlatformException(code: 'SAVE_FAILED', message: 'disk full'),
      );
      await expectLater(
        failing.saveToGallery(video.path),
        throwsA(
          isA<VideoExportException>().having(
            (error) => error.code,
            'code',
            VideoExportErrorCode.saveFailed,
          ),
        ),
      );
      final refused = VideoExportService(invokeNative: (_, _) async => false);
      await expectLater(
        refused.saveToGallery(video.path),
        throwsA(isA<VideoExportException>()),
      );
    });

    test('missing source file fails with notFound', () async {
      final service = VideoExportService(invokeNative: (_, _) async => true);
      await expectLater(
        service.saveToGallery('${root.path}/missing.ts'),
        throwsA(
          isA<VideoExportException>().having(
            (error) => error.code,
            'code',
            VideoExportErrorCode.notFound,
          ),
        ),
      );
    });
  });
}
