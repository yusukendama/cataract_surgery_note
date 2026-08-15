import 'dart:io';

import 'package:cataract_surgery_note/src/data/file_sha256.dart';
import 'package:cataract_surgery_note/src/data/video_path_classifier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('classifyVideoPath', () {
    const recordId = 'record-1';

    test('nullだけを未登録として扱う', () {
      expect(
        classifyVideoPath(recordId: recordId, videoPath: null).kind,
        VideoPathKind.unregistered,
      );
      expect(
        classifyVideoPath(recordId: recordId, videoPath: '').kind,
        VideoPathKind.invalidReference,
      );
    });

    test('同じrecordIdかつ単一ファイル名の厳密な相対pathだけを管理対象にする', () {
      expect(
        classifyVideoPath(
          recordId: recordId,
          videoPath: 'videos/record-1/video.mp4',
        ).kind,
        VideoPathKind.managed,
      );

      for (final path in <String>[
        'videos/record-2/video.mp4',
        'videos/record-1/nested/video.mp4',
        'other/record-1/video.mp4',
        'video.mp4',
      ]) {
        expect(
          classifyVideoPath(recordId: recordId, videoPath: path).kind,
          VideoPathKind.invalidReference,
          reason: path,
        );
      }
    });

    test('dot segment・重複separator・backslash・NULを正規化せず拒否する', () {
      for (final path in <String>[
        'videos/record-1/../video.mp4',
        'videos/./record-1/video.mp4',
        'videos//record-1/video.mp4',
        r'videos\record-1\video.mp4',
        'videos/record-1/video\u0000.mp4',
      ]) {
        expect(
          classifyVideoPath(recordId: recordId, videoPath: path).kind,
          VideoPathKind.invalidReference,
          reason: path,
        );
      }
    });

    test('canonicalな絶対pathだけを旧外部参照として扱う', () {
      expect(
        classifyVideoPath(
          recordId: recordId,
          videoPath: '/private/tmp/video.mp4',
        ).kind,
        VideoPathKind.legacyExternal,
      );
      for (final path in <String>[
        '/private/tmp/../tmp/video.mp4',
        '/private//tmp/video.mp4',
        '/private/tmp/./video.mp4',
      ]) {
        expect(
          classifyVideoPath(recordId: recordId, videoPath: path).kind,
          VideoPathKind.invalidReference,
          reason: path,
        );
      }
    });

    test('不正recordIdでは管理pathにも絶対pathにも昇格しない', () {
      for (final invalidId in <String>[
        '',
        '.',
        '..',
        'a/b',
        r'a\b',
        'a\u0000b',
      ]) {
        expect(isValidRecordId(invalidId), isFalse, reason: invalidId);
        expect(
          classifyVideoPath(
            recordId: invalidId,
            videoPath: '/private/tmp/video.mp4',
          ).kind,
          VideoPathKind.invalidReference,
        );
      }
    });
  });

  test('streaming SHA-256が既知のdigestと一致する', () async {
    final directory = await Directory.systemTemp.createTemp('sha256_test_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File(p.join(directory.path, 'abc.bin'));
    await file.writeAsString('abc');

    expect(
      await sha256OfFile(file),
      'ba7816bf8f01cfea414140de5dae2223'
      'b00361a396177a9cb410ff61f20015ad',
    );
  });
}
