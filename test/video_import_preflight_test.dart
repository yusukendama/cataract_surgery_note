import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/protected_storage.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:cataract_surgery_note/src/data/video_source_access_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _evidence = VideoPlaybackEvidence(
  duration: Duration(seconds: 12),
  width: 1920,
  height: 1080,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'video_preflight_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'registration/guidance allowlists are disjoint and picker list is union',
    () {
      expect(
        registrationCandidateExtensions.intersection(guidanceOnlyExtensions),
        isEmpty,
      );
      expect(selectableVideoExtensions.toSet(), <String>{
        ...registrationCandidateExtensions,
        ...guidanceOnlyExtensions,
      });
    },
  );

  test(
    'guidance-only and contract-violating suffixes never acquire source',
    () async {
      final sourceAccess = _TrackingSourceAccessRepository();
      const policy = VideoSelectionPolicy();
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: sourceAccess,
        playbackProbe: const _SuccessfulProbe(),
        protectedDataRepository: const _UnavailableProtectedDataRepository(),
      );
      final names = <String>[
        ...guidanceOnlyExtensions.map((extension) => 'patient.$extension'),
        'outside.xyz',
        'without_extension',
      ];

      for (var index = 0; index < names.length; index++) {
        final result = await preflight.inspectSelection(
          SelectedSurgeryVideo(
            path: '/path/that/must/not/be/opened.mp4',
            displayName: names[index],
          ),
          selectionGeneration: index + 1,
        );
        expect(result, isA<VideoSelectionNonCandidate>());
        expect(
          (result as VideoSelectionNonCandidate).normalizedExtension,
          policy.normalizeExtension(names[index]),
        );
      }
      expect(sourceAccess.acquireCount, 0);
    },
  );

  test(
    'displayName is authoritative over path and uppercase is normalized',
    () async {
      final file = await _writeFile(
        temporaryDirectory,
        'provider-cache.bin',
        256,
        seed: 4,
      );
      final sourceAccess = _TrackingSourceAccessRepository();
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: sourceAccess,
        playbackProbe: const _SuccessfulProbe(),
      );

      final result = await preflight.inspectSelection(
        SelectedSurgeryVideo(path: file.path, displayName: 'SURGERY.MP4'),
        selectionGeneration: 8,
      );

      final candidate = (result as VideoSelectionReady).candidate;
      expect(candidate.normalizedExtension, 'mp4');
      expect(candidate.selectionGeneration, 8);
      expect(candidate.sha256, hasLength(64));
      expect(candidate.playbackEvidence, same(_evidence));
      expect(sourceAccess.releaseCount, 1);
    },
  );

  test(
    'admission reacquires source and retains lease through storage operation',
    () async {
      final file = await _writeFile(
        temporaryDirectory,
        'source.mp4',
        512,
        seed: 7,
      );
      final sourceAccess = _TrackingSourceAccessRepository(
        sourceIdentifier: 'stable-id',
      );
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: sourceAccess,
        playbackProbe: const _SuccessfulProbe(),
      );
      final ready = await preflight.inspectSelection(
        SelectedSurgeryVideo(path: file.path, displayName: 'source.mp4'),
        selectionGeneration: 1,
      );
      final candidate = (ready as VideoSelectionReady).candidate;

      final result = await preflight.withRevalidatedImport(
        candidate,
        operation: (admitted) async {
          expect(sourceAccess.activeLeaseCount, 1);
          expect(admitted.sourceIdentifier, 'stable-id');
          return admitted.sha256;
        },
      );

      expect(result, candidate.sha256);
      expect(sourceAccess.acquireCount, 2);
      expect(sourceAccess.releaseCount, 2);
      expect(sourceAccess.activeLeaseCount, 0);
    },
  );

  test(
    'same-size and same-mtime source replacement is rejected by SHA-256',
    () async {
      final file = await _writeFile(
        temporaryDirectory,
        'source.mov',
        512,
        seed: 1,
      );
      final fixedModifiedAt = DateTime.fromMillisecondsSinceEpoch(
        1700000000000,
      );
      await file.setLastModified(fixedModifiedAt);
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: _TrackingSourceAccessRepository(),
        playbackProbe: const _SuccessfulProbe(),
      );
      final ready = await preflight.inspectSelection(
        SelectedSurgeryVideo(path: file.path, displayName: 'source.mov'),
        selectionGeneration: 1,
      );
      final candidate = (ready as VideoSelectionReady).candidate;
      await file.writeAsBytes(
        List<int>.generate(512, (index) => (index + 99) % 251),
        flush: true,
      );
      await file.setLastModified(fixedModifiedAt);

      await expectLater(
        () => preflight.withRevalidatedImport(
          candidate,
          operation: (_) async => fail('operation must not run'),
        ),
        throwsA(
          isA<VideoImportException>()
              .having(
                (error) => error.code,
                'code',
                VideoImportErrorCode.sourceChanged,
              )
              .having(
                (error) => error.internalReason,
                'reason',
                VideoImportInternalReasonV1.sourceHashMismatch,
              ),
        ),
      );
    },
  );

  test(
    'hash cancellation is typed and always releases the source lease',
    () async {
      final file = await _writeFile(
        temporaryDirectory,
        'large.m4v',
        1024 * 1024,
        seed: 12,
      );
      final sourceAccess = _TrackingSourceAccessRepository();
      final token = VideoImportCancellationToken();
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: sourceAccess,
        playbackProbe: const _SuccessfulProbe(),
      );

      await expectLater(
        () => preflight.inspectSelection(
          SelectedSurgeryVideo(path: file.path, displayName: 'large.m4v'),
          selectionGeneration: 1,
          cancellationToken: token,
          onProgress: (progress) {
            if (progress.phase == VideoImportPhase.sourceHash &&
                progress.fraction != null) {
              token.cancel();
            }
          },
        ),
        throwsA(
          isA<VideoImportException>().having(
            (error) => error.code,
            'code',
            VideoImportErrorCode.userCanceled,
          ),
        ),
      );
      expect(sourceAccess.activeLeaseCount, 0);
      expect(sourceAccess.releaseCount, 1);
    },
  );

  test('source lease failures retain access/provider distinction', () async {
    final missing = DefaultVideoImportPreflight(
      sourceAccessRepository: _TrackingSourceAccessRepository(
        failureReason: VideoSourceAccessFailureReason.sourceNotFound,
      ),
      playbackProbe: const _SuccessfulProbe(),
    );
    final denied = DefaultVideoImportPreflight(
      sourceAccessRepository: _TrackingSourceAccessRepository(
        failureReason: VideoSourceAccessFailureReason.accessDenied,
      ),
      playbackProbe: const _SuccessfulProbe(),
    );
    final unavailable = DefaultVideoImportPreflight(
      sourceAccessRepository: _TrackingSourceAccessRepository(
        failureReason: VideoSourceAccessFailureReason.providerUnavailable,
      ),
      playbackProbe: const _SuccessfulProbe(),
    );
    final protectedDataUnavailable = DefaultVideoImportPreflight(
      sourceAccessRepository: _TrackingSourceAccessRepository(
        failureReason: VideoSourceAccessFailureReason.protectedDataUnavailable,
      ),
      playbackProbe: const _SuccessfulProbe(),
    );
    const selection = SelectedSurgeryVideo(
      path: '/unavailable/source',
      displayName: 'source.mp4',
    );

    await expectLater(
      () => missing.inspectSelection(selection, selectionGeneration: 1),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.sourceNotFound,
        ),
      ),
    );
    await expectLater(
      () => denied.inspectSelection(selection, selectionGeneration: 1),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.sourceAccessDenied,
        ),
      ),
    );
    await expectLater(
      () => unavailable.inspectSelection(selection, selectionGeneration: 1),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.providerUnavailable,
        ),
      ),
    );
    await expectLater(
      () => protectedDataUnavailable.inspectSelection(
        selection,
        selectionGeneration: 1,
      ),
      throwsA(
        isA<VideoImportException>()
            .having(
              (error) => error.code,
              'code',
              VideoImportErrorCode.protectedDataUnavailable,
            )
            .having(
              (error) => error.primaryRecoveryAction,
              'primaryRecoveryAction',
              VideoImportRecoveryAction.unlockAndRetry,
            ),
      ),
    );
  });

  test(
    'iOS source channel preserves protected-data-unavailable classification',
    () async {
      const channel = MethodChannel('test/video-source-access');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'acquire');
        throw PlatformException(code: 'protected_data_unavailable');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const repository = PlatformVideoSourceAccessRepository(
        methodChannel: channel,
        isIOSOverride: true,
      );

      await expectLater(
        () => repository.acquire(
          const SelectedSurgeryVideo(
            path: '/must/not/open.mp4',
            displayName: 'source.mp4',
          ),
        ),
        throwsA(
          isA<VideoSourceAccessException>().having(
            (error) => error.reason,
            'reason',
            VideoSourceAccessFailureReason.protectedDataUnavailable,
          ),
        ),
      );
    },
  );

  test('protected data unavailable blocks work before source access', () async {
    final sourceAccess = _TrackingSourceAccessRepository();
    final preflight = DefaultVideoImportPreflight(
      sourceAccessRepository: sourceAccess,
      playbackProbe: const _SuccessfulProbe(),
      protectedDataRepository: const _UnavailableProtectedDataRepository(),
    );

    await expectLater(
      () => preflight.inspectSelection(
        const SelectedSurgeryVideo(
          path: '/must/not/open',
          displayName: 'source.mp4',
        ),
        selectionGeneration: 1,
      ),
      throwsA(
        isA<VideoImportException>().having(
          (error) => error.code,
          'code',
          VideoImportErrorCode.protectedDataUnavailable,
        ),
      ),
    );
    expect(sourceAccess.acquireCount, 0);
  });

  for (final testCase
      in <
        ({
          VideoPlaybackProbeFailureReason reason,
          VideoImportErrorCode code,
          VideoImportInternalReasonV1 internalReason,
        })
      >[
        (
          reason: VideoPlaybackProbeFailureReason.initialization,
          code: VideoImportErrorCode.unplayableMedia,
          internalReason: VideoImportInternalReasonV1.playerInitFailed,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.invalidDuration,
          code: VideoImportErrorCode.unplayableMedia,
          internalReason: VideoImportInternalReasonV1.playerInvalidDuration,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.invalidDimensions,
          code: VideoImportErrorCode.unplayableMedia,
          internalReason: VideoImportInternalReasonV1.playerInvalidDimensions,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.noProgress,
          code: VideoImportErrorCode.unplayableMedia,
          internalReason: VideoImportInternalReasonV1.playerNoProgress,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.seek,
          code: VideoImportErrorCode.unplayableMedia,
          internalReason: VideoImportInternalReasonV1.playerSeekFailed,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.protectedMedia,
          code: VideoImportErrorCode.protectedMedia,
          internalReason: VideoImportInternalReasonV1.drmSignaled,
        ),
        (
          reason: VideoPlaybackProbeFailureReason.timedOut,
          code: VideoImportErrorCode.playbackVerificationTimedOut,
          internalReason: VideoImportInternalReasonV1.stageTimeout,
        ),
      ]) {
    test('probe ${testCase.reason.name} has closed domain mapping', () async {
      final file = await _writeFile(
        temporaryDirectory,
        'source.mp4',
        64,
        seed: 3,
      );
      final preflight = DefaultVideoImportPreflight(
        sourceAccessRepository: _TrackingSourceAccessRepository(),
        playbackProbe: _FailingProbe(testCase.reason),
      );

      await expectLater(
        () => preflight.inspectSelection(
          SelectedSurgeryVideo(path: file.path, displayName: 'source.mp4'),
          selectionGeneration: 1,
        ),
        throwsA(
          isA<VideoImportException>()
              .having((error) => error.code, 'code', testCase.code)
              .having(
                (error) => error.internalReason,
                'reason',
                testCase.internalReason,
              ),
        ),
      );
    });
  }
}

Future<File> _writeFile(
  Directory directory,
  String name,
  int length, {
  required int seed,
}) async {
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(
    List<int>.generate(length, (index) => (index + seed) % 251),
    flush: true,
  );
  return file;
}

class _SuccessfulProbe implements VideoPlaybackProbe {
  const _SuccessfulProbe();

  @override
  Future<VideoPlaybackEvidence> probe(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async => _evidence;
}

class _FailingProbe implements VideoPlaybackProbe {
  const _FailingProbe(this.reason);

  final VideoPlaybackProbeFailureReason reason;

  @override
  Future<VideoPlaybackEvidence> probe(
    File file, {
    VideoImportCancellationToken? cancellationToken,
  }) async {
    throw VideoPlaybackProbeException(reason);
  }
}

class _TrackingSourceAccessRepository implements VideoSourceAccessRepository {
  _TrackingSourceAccessRepository({this.sourceIdentifier, this.failureReason});

  final String? sourceIdentifier;
  final VideoSourceAccessFailureReason? failureReason;
  int acquireCount = 0;
  int releaseCount = 0;
  int activeLeaseCount = 0;

  @override
  Future<VideoSourceAccessLease> acquire(SelectedSurgeryVideo reference) async {
    acquireCount++;
    final failure = failureReason;
    if (failure != null) {
      throw VideoSourceAccessException(failure);
    }
    activeLeaseCount++;
    return _TrackingLease(
      file: File(reference.path),
      sourceIdentifier: sourceIdentifier,
      onRelease: () {
        releaseCount++;
        activeLeaseCount--;
      },
    );
  }
}

class _TrackingLease implements VideoSourceAccessLease {
  _TrackingLease({
    required this.file,
    required this.sourceIdentifier,
    required this.onRelease,
  });

  @override
  final File file;
  @override
  final String? sourceIdentifier;
  final void Function() onRelease;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    onRelease();
  }
}

class _UnavailableProtectedDataRepository implements ProtectedDataRepository {
  const _UnavailableProtectedDataRepository();

  @override
  Stream<bool> get availabilityChanges => const Stream<bool>.empty();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<void> requireAvailable() async {
    throw const ProtectedDataUnavailableException();
  }
}
