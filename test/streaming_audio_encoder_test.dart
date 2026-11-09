import 'dart:typed_data';

import 'package:camera_station/services/recording_service.dart';
import 'package:camera_station/services/streaming_audio_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Header WAV PCM; [extraChunk] chèn trước `data` (ví dụ FLLR của iOS).
Uint8List wavHeader({
  int sampleRate = 48000,
  int channels = 1,
  int bits = 16,
  int format = 1,
  int dataBytes = 0,
  int extraChunkBytes = 0,
}) {
  final size = 12 + 24 + (extraChunkBytes > 0 ? 8 + extraChunkBytes : 0) + 8;
  final bytes = ByteData(size);
  var o = 0;
  void tag(String t) {
    for (final c in t.codeUnits) {
      bytes.setUint8(o++, c);
    }
  }

  void u32(int v) {
    bytes.setUint32(o, v, Endian.little);
    o += 4;
  }

  void u16(int v) {
    bytes.setUint16(o, v, Endian.little);
    o += 2;
  }

  tag('RIFF');
  u32(size - 8 + dataBytes);
  tag('WAVE');
  tag('fmt ');
  u32(16);
  u16(format);
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * bits ~/ 8);
  u16(channels * bits ~/ 8);
  u16(bits);
  if (extraChunkBytes > 0) {
    tag('FLLR');
    u32(extraChunkBytes);
    o += extraChunkBytes;
  }
  tag('data');
  u32(dataBytes);
  return bytes.buffer.asUint8List();
}

void main() {
  group('parseWavPcmLayout', () {
    test('Android header while recording (data size 0)', () {
      final layout = parseWavPcmLayout(wavHeader())!;
      expect(layout.dataOffset, 44);
      expect(layout.declaredDataBytes, isNull);
      expect(layout.sampleRate, 48000);
      expect(layout.channels, 1);
      expect(layout.blockAlign, 2);
    });

    test('finalized header reports the PCM size', () {
      final layout = parseWavPcmLayout(wavHeader(dataBytes: 96000))!;
      expect(layout.declaredDataBytes, 96000);
    });

    test('skips filler chunks before data (iOS)', () {
      final layout = parseWavPcmLayout(
        wavHeader(sampleRate: 44100, extraChunkBytes: 4044),
      )!;
      expect(layout.dataOffset, 12 + 24 + 8 + 4044 + 8);
      expect(layout.sampleRate, 44100);
    });

    test('rejects incomplete or unsupported headers', () {
      expect(parseWavPcmLayout(Uint8List(0)), isNull);
      expect(parseWavPcmLayout(wavHeader().sublist(0, 40)), isNull);
      expect(parseWavPcmLayout(wavHeader(bits: 24)), isNull);
      expect(parseWavPcmLayout(wavHeader(format: 3)), isNull);
    });
  });

  test('availablePcmBytes caps at file end, header size and sample frame', () {
    expect(
      availablePcmBytes(dataOffset: 44, blockAlign: 2, fileLength: 44 + 1001),
      1000,
    );
    expect(
      availablePcmBytes(
        dataOffset: 44,
        blockAlign: 2,
        fileLength: 44 + 5000,
        declaredDataBytes: 4000,
      ),
      4000,
    );
    expect(
      availablePcmBytes(dataOffset: 44, blockAlign: 2, fileLength: 30),
      0,
    );
  });

  test('streaming encoder uses the WAV format and the same audio filter', () {
    final args = streamingAudioEncodeArguments(
      pipePath: '/cache/pipe1',
      aacPath: '/staging/a.aac',
      layout: parseWavPcmLayout(wavHeader(sampleRate: 44100))!,
      filter: 'highpass=f=150',
    );
    expect(args.join(' '), contains('-f s16le -ar 44100 -ac 1 -i /cache/pipe1'));
    expect(args.join(' '), contains('-af highpass=f=150 -c:a aac -b:a 128k'));
    expect(args.last, '/staging/a.aac');
  });

  group('preEncodedAudioOffsetArguments', () {
    test('compensates the 1024-sample AAC priming when in sync', () {
      expect(preEncodedAudioOffsetArguments(null, sampleRate: 48000), [
        '-itsoffset',
        '-0.021333',
      ]);
      // Lệch rất nhỏ hoặc vô lý: bỏ qua như audioOffsetInputArguments.
      expect(preEncodedAudioOffsetArguments(10, sampleRate: 48000), [
        '-itsoffset',
        '-0.021333',
      ]);
      expect(preEncodedAudioOffsetArguments(5000, sampleRate: 48000), [
        '-itsoffset',
        '-0.021333',
      ]);
    });

    test('audio later than video: delay it, minus priming', () {
      expect(preEncodedAudioOffsetArguments(300, sampleRate: 48000), [
        '-itsoffset',
        '0.278667',
      ]);
    });

    test('audio earlier than video: cut its start, then priming', () {
      expect(preEncodedAudioOffsetArguments(-300, sampleRate: 48000), [
        '-ss',
        '0.300',
        '-itsoffset',
        '-0.021333',
      ]);
    });

    test('priming follows the sample rate', () {
      expect(preEncodedAudioOffsetArguments(0, sampleRate: 44100), [
        '-itsoffset',
        '-0.023220',
      ]);
    });
  });
}
