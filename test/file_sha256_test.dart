import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/file_sha256.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('byte buffer SHA-256 matches the standard digest', () {
    expect(
      sha256OfBytes(const <int>[]),
      'e3b0c44298fc1c149afbf4c8996fb924'
      '27ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256OfBytes(const <int>[0x61, 0x62, 0x63]),
      'ba7816bf8f01cfea414140de5dae2223'
      'b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256OfBytes(
        utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      ),
      '248d6a61d20638b8e5c026930c3e6039'
      'a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('streaming SHA-256 is independent of chunk boundaries', () async {
    final bytes = utf8.encode(
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
    );

    final digest = await sha256OfFile(
      File('/synthetic/chunked.mp4'),
      readLength: (_) async => bytes.length,
      openRead: (_) => Stream<List<int>>.fromIterable(<List<int>>[
        bytes.sublist(0, 1),
        bytes.sublist(1, 17),
        bytes.sublist(17, 49),
        bytes.sublist(49),
      ]),
    );

    expect(
      digest,
      '248d6a61d20638b8e5c026930c3e6039'
      'a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('streamが無応答でもcancel signalで待機を終了しsubscriptionを解放する', () async {
    final streamCancelled = Completer<void>();
    final stream = StreamController<List<int>>(
      onCancel: () {
        if (!streamCancelled.isCompleted) {
          streamCancelled.complete();
        }
      },
    );
    final token = VideoImportCancellationToken();

    final hashing = sha256OfFile(
      File('/synthetic/stalled.mp4'),
      cancellationSignal: token.whenCancelled,
      readLength: (_) async => 1024,
      openRead: (_) => stream.stream,
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();

    await expectLater(
      hashing.timeout(const Duration(seconds: 2)),
      throwsA(isA<FileSystemException>()),
    );
    await streamCancelled.future.timeout(const Duration(seconds: 2));
    await stream.close();
  });
}
