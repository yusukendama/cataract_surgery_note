import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:cataract_surgery_note/src/features/video_import/video_import_ui_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'picker cancel returns cancellation without running preflight',
    () async {
      final picker = _QueuePicker(<FutureOr<SelectedSurgeryVideo?>>[null]);
      final preflight = _FakePreflight((
        selection,
        generation,
        token,
        progress,
      ) {
        fail('preflight must not run after picker cancellation');
      });
      final flow = VideoImportUiFlow(picker: picker, preflight: preflight);

      final result = await flow.selectAndInspect();

      expect(result, isA<VideoImportUiCancelled>());
      expect(result.selectionGeneration, 1);
      expect(preflight.inspectCallCount, 0);
      expect(flow.isActive, isFalse);
    },
  );

  test('ready candidate and progress retain the same generation', () async {
    const selection = SelectedSurgeryVideo(
      path: '/synthetic/video.mp4',
      displayName: 'video.MP4',
    );
    final picker = _QueuePicker(<FutureOr<SelectedSurgeryVideo?>>[selection]);
    final seenProgress = <VideoImportProgress>[];
    final preflight = _FakePreflight((selected, generation, token, progress) {
      expect(selected, same(selection));
      expect(token, isNotNull);
      progress?.call(
        const VideoImportProgress(phase: VideoImportPhase.sourceHash),
      );
      return VideoSelectionReady(_candidate(generation));
    });
    final flow = VideoImportUiFlow(picker: picker, preflight: preflight);

    final result = await flow.selectAndInspect(onProgress: seenProgress.add);

    expect(result, isA<VideoImportUiReady>());
    final ready = result as VideoImportUiReady;
    expect(ready.selectionGeneration, 1);
    expect(ready.candidate.selectionGeneration, 1);
    expect(seenProgress.single.phase, VideoImportPhase.sourceHash);
  });

  test('non-candidate is returned as metadata-only result', () async {
    final picker = _QueuePicker(<FutureOr<SelectedSurgeryVideo?>>[
      const SelectedSurgeryVideo(
        path: '/must/not/be/opened.mpg',
        displayName: 'fixture.MPG',
      ),
    ]);
    final preflight = _FakePreflight((selection, generation, token, progress) {
      return const VideoSelectionNonCandidate(normalizedExtension: 'mpg');
    });
    final flow = VideoImportUiFlow(picker: picker, preflight: preflight);

    final result = await flow.selectAndInspect();

    expect(result, isA<VideoImportUiNonCandidate>());
    expect((result as VideoImportUiNonCandidate).normalizedExtension, 'mpg');
  });

  test('a second start is suppressed while one generation is active', () async {
    final inspected = Completer<VideoSelectionPreflightResult>();
    final picker = _QueuePicker(<FutureOr<SelectedSurgeryVideo?>>[
      const SelectedSurgeryVideo(
        path: '/synthetic/first.mp4',
        displayName: 'first.mp4',
      ),
    ]);
    final preflight = _FakePreflight((selection, generation, token, progress) {
      return inspected.future;
    });
    final flow = VideoImportUiFlow(picker: picker, preflight: preflight);

    final first = flow.selectAndInspect();
    await Future<void>.delayed(Duration.zero);
    final second = await flow.selectAndInspect();

    expect(second, isA<VideoImportUiBusy>());
    expect(second.selectionGeneration, 1);
    expect(picker.callCount, 1);
    expect(preflight.inspectCallCount, 1);

    inspected.complete(VideoSelectionReady(_candidate(1)));
    expect(await first, isA<VideoImportUiReady>());
  });

  test(
    'cancel invalidates late completion and allows a new generation',
    () async {
      final firstInspection = Completer<VideoSelectionPreflightResult>();
      VideoImportCancellationToken? firstToken;
      VideoImportProgressCallback? firstProgress;
      var inspection = 0;
      final picker = _QueuePicker(<FutureOr<SelectedSurgeryVideo?>>[
        const SelectedSurgeryVideo(
          path: '/synthetic/first.mp4',
          displayName: 'first.mp4',
        ),
        const SelectedSurgeryVideo(
          path: '/synthetic/second.mp4',
          displayName: 'second.mp4',
        ),
      ]);
      final preflight = _FakePreflight((
        selection,
        generation,
        token,
        progress,
      ) {
        inspection++;
        if (inspection == 1) {
          firstToken = token;
          firstProgress = progress;
          return firstInspection.future;
        }
        return VideoSelectionReady(_candidate(generation));
      });
      final seenProgress = <VideoImportProgress>[];
      final flow = VideoImportUiFlow(picker: picker, preflight: preflight);

      final first = flow.selectAndInspect(onProgress: seenProgress.add);
      await Future<void>.delayed(Duration.zero);
      expect(flow.cancelActive(), isTrue);
      expect(firstToken?.isCancelled, isTrue);
      firstProgress?.call(
        const VideoImportProgress(phase: VideoImportPhase.sourcePlayback),
      );
      expect(seenProgress, isEmpty);

      final second = await flow.selectAndInspect();
      expect(second.selectionGeneration, 2);
      expect(second, isA<VideoImportUiReady>());

      firstInspection.complete(VideoSelectionReady(_candidate(1)));
      expect(await first, isA<VideoImportUiCancelled>());
      expect(flow.isActive, isFalse);
    },
  );

  test(
    'picker filesystem failure is mapped without exposing raw details',
    () async {
      final flow = VideoImportUiFlow(
        picker: _ThrowingPicker(
          const FileSystemException(
            'synthetic provider detail',
            '/private/synthetic-name.mp4',
          ),
        ),
        preflight: _FakePreflight((selection, generation, token, progress) {
          fail('preflight must not run');
        }),
      );

      final result = await flow.selectAndInspect();

      expect(result, isA<VideoImportUiFailure>());
      final error = (result as VideoImportUiFailure).error;
      expect(error.code, VideoImportErrorCode.providerUnavailable);
      expect(
        error.internalReason,
        VideoImportInternalReasonV1.providerUnavailable,
      );
      expect(error.toString(), isNot(contains('synthetic-name')));
    },
  );
}

VerifiedVideoCandidate _candidate(int generation) {
  return VerifiedVideoCandidate(
    path: '/synthetic/candidate.mp4',
    displayName: 'candidate.mp4',
    normalizedExtension: 'mp4',
    selectionGeneration: generation,
    sourceSize: 1024,
    sourceModifiedAt: DateTime.utc(2026),
    sha256: 'synthetic-sha256',
    playbackEvidence: const VideoPlaybackEvidence(
      duration: Duration(seconds: 30),
      width: 1920,
      height: 1080,
    ),
  );
}

typedef _Inspect =
    FutureOr<VideoSelectionPreflightResult> Function(
      SelectedSurgeryVideo selection,
      int generation,
      VideoImportCancellationToken? cancellationToken,
      VideoImportProgressCallback? onProgress,
    );

class _FakePreflight implements VideoImportPreflight {
  _FakePreflight(this._inspect);

  final _Inspect _inspect;
  int inspectCallCount = 0;

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    inspectCallCount++;
    return _inspect(
      selection,
      selectionGeneration,
      cancellationToken,
      onProgress,
    );
  }

  @override
  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    return operation(candidate);
  }
}

class _QueuePicker implements SurgeryVideoPicker {
  _QueuePicker(this._results);

  final List<FutureOr<SelectedSurgeryVideo?>> _results;
  int callCount = 0;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async {
    callCount++;
    return _results.removeAt(0);
  }
}

class _ThrowingPicker implements SurgeryVideoPicker {
  const _ThrowingPicker(this.error);

  final Object error;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() => Future.error(error);
}
