import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_video_picker.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_import_preflight.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/records/new_record_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/video_import_test_support.dart';

void main() {
  late Directory tempDirectory;
  late VideoPlayerPlatform originalPlatform;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'new_record_preview_change_',
    );
    originalPlatform = VideoPlayerPlatform.instance;
  });

  tearDown(() async {
    VideoPlayerPlatform.instance = originalPlatform;
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'best-effort preview failure does not reject verified candidate',
    (tester) async {
      final initialFile = (await tester.runAsync(
        () => _writeVideo(tempDirectory, 'first.mp4', 1),
      ))!;
      final pendingFile = (await tester.runAsync(
        () => _writeVideo(tempDirectory, 'pending.mp4', 2),
      ))!;
      final initialCandidate = (await tester.runAsync(
        () => verifiedVideoCandidateForFile(initialFile),
      ))!;
      final pendingCandidate = (await tester.runAsync(
        () => verifiedVideoCandidateForFile(pendingFile),
      ))!;
      final platform = _PreviewVideoPlayerPlatform(failingPlayerIds: const {2});
      VideoPlayerPlatform.instance = platform;

      await _pumpScreen(
        tester,
        initialCandidate: initialCandidate,
        selectedCandidate: pendingCandidate,
        picker: _QueueVideoPicker(
          SelectedSurgeryVideo(
            path: pendingFile.path,
            displayName: 'pending.mp4',
          ),
        ),
      );
      await _enterRequiredFields(tester);

      await _scrollToTop(tester);
      await tester.tap(find.text('動画を変更'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();

      expect(find.text('プレビューできません'), findsOneWidget);
      expect(find.text('pending.mp4'), findsOneWidget);
      expect(find.text('first.mp4'), findsNothing);
      expect(platform.disposeRequests, contains(1));
      expect(platform.activePlayerIds, isNot(contains(1)));
      expect(platform.activePlayerIds, isNot(contains(2)));
      await _scrollToForm(tester);
      expect(_selectedEye(tester), isEmpty);
      expect(find.text('未選択'), findsOneWidget);
    },
  );

  testWidgets(
    'verified candidate is adopted and best-effort preview succeeds',
    (tester) async {
      final initialFile = (await tester.runAsync(
        () => _writeVideo(tempDirectory, 'first.mp4', 1),
      ))!;
      final replacementFile = (await tester.runAsync(
        () => _writeVideo(tempDirectory, 'replacement.mp4', 2),
      ))!;
      final initialCandidate = (await tester.runAsync(
        () => verifiedVideoCandidateForFile(initialFile),
      ))!;
      final replacementCandidate = (await tester.runAsync(
        () => verifiedVideoCandidateForFile(replacementFile),
      ))!;
      final platform = _PreviewVideoPlayerPlatform();
      VideoPlayerPlatform.instance = platform;

      await _pumpScreen(
        tester,
        initialCandidate: initialCandidate,
        selectedCandidate: replacementCandidate,
        picker: _QueueVideoPicker(
          SelectedSurgeryVideo(
            path: replacementFile.path,
            displayName: 'replacement.mp4',
          ),
        ),
      );
      await _enterRequiredFields(tester);

      await _scrollToTop(tester);
      await tester.tap(find.text('動画を変更'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();

      expect(find.text('replacement.mp4'), findsOneWidget);
      expect(find.text('first.mp4'), findsNothing);
      expect(platform.activePlayerIds, contains(2));
      expect(platform.activePlayerIds, isNot(contains(1)));
      await _scrollToForm(tester);
      expect(_selectedEye(tester), isEmpty);
      expect(find.text('未選択'), findsOneWidget);
      expect(find.textContaining('再確認してください'), findsOneWidget);
    },
  );

  testWidgets('a newer video change cancels and disposes a pending preview', (
    tester,
  ) async {
    final initialFile = (await tester.runAsync(
      () => _writeVideo(tempDirectory, 'first.mp4', 1),
    ))!;
    final pendingFile = (await tester.runAsync(
      () => _writeVideo(tempDirectory, 'pending.mp4', 2),
    ))!;
    final latestFile = (await tester.runAsync(
      () => _writeVideo(tempDirectory, 'latest.mp4', 3),
    ))!;
    final initialCandidate = (await tester.runAsync(
      () => verifiedVideoCandidateForFile(initialFile),
    ))!;
    final pendingCandidate = (await tester.runAsync(
      () => verifiedVideoCandidateForFile(pendingFile),
    ))!;
    final latestCandidate = (await tester.runAsync(
      () => verifiedVideoCandidateForFile(latestFile),
    ))!;
    final platform = _PreviewVideoPlayerPlatform(pendingPlayerIds: const {2});
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryVideoPickerProvider.overrideWithValue(
            _SequenceVideoPicker([
              SelectedSurgeryVideo(
                path: pendingFile.path,
                displayName: 'pending.mp4',
              ),
              SelectedSurgeryVideo(
                path: latestFile.path,
                displayName: 'latest.mp4',
              ),
            ]),
          ),
          videoImportPreflightProvider.overrideWithValue(
            _CandidatesByPathPreflight({
              pendingFile.path: pendingCandidate,
              latestFile.path: latestCandidate,
            }),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: NewRecordScreen(initialVideo: initialCandidate),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToTop(tester);
    await tester.tap(find.text('動画を変更'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(find.text('pending.mp4'), findsOneWidget);
    expect(platform.activePlayerIds, contains(2));

    await tester.tap(find.text('動画を変更'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(find.text('latest.mp4'), findsOneWidget);
    expect(platform.activePlayerIds, contains(3));
    expect(platform.activePlayerIds, isNot(contains(1)));
    expect(platform.activePlayerIds, isNot(contains(2)));
    expect(platform.disposeRequests, containsAll(<int>[1, 2]));
  });
}

Future<File> _writeVideo(Directory directory, String name, int byte) async {
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(List<int>.filled(64, byte));
  return file;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required VerifiedVideoCandidate initialCandidate,
  required VerifiedVideoCandidate selectedCandidate,
  required SurgeryVideoPicker picker,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        surgeryVideoPickerProvider.overrideWithValue(picker),
        videoImportPreflightProvider.overrideWithValue(
          _SelectedCandidatePreflight(selectedCandidate),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: NewRecordScreen(initialVideo: initialCandidate),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enterRequiredFields(WidgetTester tester) async {
  await _scrollToForm(tester);
  await tester.tap(find.text('手術日（必須）'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('左眼'));
  await tester.pumpAndSettle();
}

Future<void> _scrollToForm(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -500));
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(WidgetTester tester) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
  }
  // The change button sits just below the 16:9 preview and controls.
  await tester.drag(find.byType(ListView), const Offset(0, -250));
  await tester.pumpAndSettle();
}

Set<EyeSide> _selectedEye(WidgetTester tester) {
  return tester
      .widget<SegmentedButton<EyeSide>>(
        find.byWidgetPredicate((widget) => widget is SegmentedButton<EyeSide>),
      )
      .selected;
}

class _QueueVideoPicker implements SurgeryVideoPicker {
  _QueueVideoPicker(this.selection);

  final SelectedSurgeryVideo selection;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async => selection;
}

class _SequenceVideoPicker implements SurgeryVideoPicker {
  _SequenceVideoPicker(this._selections);

  final List<SelectedSurgeryVideo> _selections;
  var _nextSelection = 0;

  @override
  Future<SelectedSurgeryVideo?> pickVideo() async {
    if (_nextSelection >= _selections.length) {
      return null;
    }
    return _selections[_nextSelection++];
  }
}

class _SelectedCandidatePreflight implements VideoImportPreflight {
  const _SelectedCandidatePreflight(this.candidate);

  final VerifiedVideoCandidate candidate;

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    return VideoSelectionReady(candidate);
  }

  @override
  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async => candidate;

  @override
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) => operation(candidate);
}

class _CandidatesByPathPreflight implements VideoImportPreflight {
  const _CandidatesByPathPreflight(this._candidates);

  final Map<String, VerifiedVideoCandidate> _candidates;

  @override
  Future<VideoSelectionPreflightResult> inspectSelection(
    SelectedSurgeryVideo selection, {
    required int selectionGeneration,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    cancellationToken?.throwIfCancelled(VideoImportPhase.sourceAccess);
    return VideoSelectionReady(_candidates[selection.path]!);
  }

  @override
  Future<VerifiedVideoCandidate> revalidateForImport(
    VerifiedVideoCandidate candidate, {
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async => candidate;

  @override
  Future<T> withRevalidatedImport<T>(
    VerifiedVideoCandidate candidate, {
    required Future<T> Function(VerifiedVideoCandidate admittedCandidate)
    operation,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) => operation(candidate);
}

class _PreviewVideoPlayerPlatform extends VideoPlayerPlatform {
  _PreviewVideoPlayerPlatform({
    this.failingPlayerIds = const <int>{},
    this.pendingPlayerIds = const <int>{},
  });

  final Set<int> failingPlayerIds;
  final Set<int> pendingPlayerIds;
  final Set<int> activePlayerIds = <int>{};
  final Set<int> disposeRequests = <int>{};
  final Map<int, Duration> _positions = <int, Duration>{};
  final Map<int, StreamController<VideoEvent>> _pendingEvents =
      <int, StreamController<VideoEvent>>{};
  var _nextPlayerId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    activePlayerIds.add(playerId);
    _positions[playerId] = Duration.zero;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    if (failingPlayerIds.contains(playerId)) {
      return Stream<VideoEvent>.error(
        PlatformException(
          code: 'synthetic_player_failure',
          message: 'synthetic player failure',
        ),
      );
    }
    if (pendingPlayerIds.contains(playerId)) {
      final events = StreamController<VideoEvent>();
      _pendingEvents[playerId] = events;
      return events.stream;
    }
    return Stream<VideoEvent>.value(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: const Size(1920, 1080),
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    disposeRequests.add(playerId);
    activePlayerIds.remove(playerId);
    _positions.remove(playerId);
    await _pendingEvents.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    return _positions[playerId] ?? Duration.zero;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return const ColoredBox(color: Colors.black, child: SizedBox.expand());
  }
}
