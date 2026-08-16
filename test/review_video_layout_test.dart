import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:cataract_surgery_note/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  const portraitViewports = [
    _ViewportScenario(
      name: '320x568',
      size: Size(320, 568),
      viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
    ),
    _ViewportScenario(
      name: '375x667',
      size: Size(375, 667),
      viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
    ),
    _ViewportScenario(
      name: '430x932',
      size: Size(430, 932),
      viewPadding: EdgeInsets.fromLTRB(0, 59, 0, 34),
    ),
    _ViewportScenario(
      name: 'compact-iPad-320x1024',
      size: Size(320, 1024),
      viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
    ),
    _ViewportScenario(
      name: 'iPad-768x1024',
      size: Size(768, 1024),
      viewPadding: EdgeInsets.fromLTRB(0, 24, 0, 20),
    ),
  ];

  for (final viewport in portraitViewports) {
    for (final textScale in const [1.0, 2.0]) {
      testWidgets('${viewport.name} 文字倍率$textScaleでプレイヤー全体を固定表示する', (
        tester,
      ) async {
        final harness = await _pumpReview(
          tester,
          viewport: viewport,
          textScale: textScale,
          videoSize: const Size(1600, 900),
        );

        _expectPinnedPlayer(tester, aspectRatio: 16 / 9);
        expect(harness.videoPlatform.createCount, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final videoSize in const [Size(1200, 900), Size(900, 1600)]) {
    testWidgets(
      '320x568 文字倍率2.0で${videoSize.width}:${videoSize.height}動画全体を表示する',
      (tester) async {
        await _pumpReview(
          tester,
          viewport: portraitViewports.first,
          textScale: 2,
          videoSize: videoSize,
        );

        _expectPinnedPlayer(
          tester,
          aspectRatio: videoSize.width / videoSize.height,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('工程領域をスクロールしてもプレイヤーの位置を維持する', (tester) async {
    await _pumpReview(
      tester,
      viewport: portraitViewports[1],
      textScale: 1,
      videoSize: const Size(1600, 900),
    );
    final before = _playerRects(tester);
    final reviewList = find.byKey(
      const ValueKey('review-step-content-totalSurgeryTime'),
    );

    await tester.drag(reviewList, const Offset(0, -600));
    await tester.pumpAndSettle();
    _expectRectsUnchanged(tester, before);

    await tester.drag(reviewList, const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('procedure-start-button')));
    await tester.pumpAndSettle();
    _expectRectsUnchanged(tester, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('キーボードを閉じると同じControllerで固定プレイヤーへ復帰する', (tester) async {
    final viewport = portraitViewports.first;
    final harness = await _pumpReview(
      tester,
      viewport: viewport,
      textScale: 2,
      videoSize: const Size(1600, 900),
    );
    await _openTab(tester, '症例メモ');
    final memo = find.widgetWithText(TextField, '症例全体のメモ');
    await tester.enterText(memo, '保持するメモ');
    await tester.pump();

    await harness.pump(
      tester,
      viewport: viewport,
      textScale: 2,
      viewInsets: const EdgeInsets.only(bottom: 300),
    );
    expect(find.byKey(const Key('review-video-player-region')), findsNothing);
    expect(tester.widget<TextField>(memo).controller!.text, '保持するメモ');

    await harness.pump(tester, viewport: viewport, textScale: 2);
    _expectPinnedPlayer(tester, aspectRatio: 16 / 9);
    expect(tester.widget<TextField>(memo).controller!.text, '保持するメモ');
    expect(harness.videoPlatform.createCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横画面の例外レイアウトから縦画面へ戻してもControllerを再生成しない', (tester) async {
    final harness = await _pumpReview(
      tester,
      viewport: portraitViewports[1],
      textScale: 1,
      videoSize: const Size(1600, 900),
    );
    const landscape = _ViewportScenario(
      name: 'landscape',
      size: Size(568, 320),
      viewPadding: EdgeInsets.fromLTRB(59, 0, 21, 21),
    );

    await harness.pump(tester, viewport: landscape, textScale: 2);
    expect(
      find.byKey(const Key('review-video-fallback-region')),
      findsOneWidget,
    );
    expect(find.byType(VideoTransportControls), findsOneWidget);
    expect(tester.takeException(), isNull);

    await harness.pump(tester, viewport: portraitViewports[1], textScale: 1);
    _expectPinnedPlayer(tester, aspectRatio: 16 / 9);
    expect(harness.videoPlatform.createCount, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<_ReviewHarness> _pumpReview(
  WidgetTester tester, {
  required _ViewportScenario viewport,
  required double textScale,
  required Size videoSize,
}) async {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  late SurgeryRecord record;
  await tester.runAsync(() async {
    final repository = SurgeryRepository(database);
    record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: 'videos/${record.id}/review.mp4',
      videoDisplayName: 'review.mp4',
    );
  });

  final videoFile = File('/tmp/cataract-surgery-note-layout-review.mp4');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => database),
      videoStorageRepositoryProvider.overrideWithValue(
        _AvailableVideoStorage(videoFile),
      ),
    ],
  );
  addTearDown(container.dispose);
  final videoPlatform = _FakeVideoPlayerPlatform(videoSize);
  VideoPlayerPlatform.instance = videoPlatform;
  final harness = _ReviewHarness(
    container: container,
    recordId: record.id,
    videoPlatform: videoPlatform,
  );
  await harness.pump(tester, viewport: viewport, textScale: textScale);
  expect(find.byKey(const Key('review-video-player')), findsOneWidget);
  return harness;
}

class _ReviewHarness {
  const _ReviewHarness({
    required this.container,
    required this.recordId,
    required this.videoPlatform,
  });

  final ProviderContainer container;
  final String recordId;
  final _FakeVideoPlayerPlatform videoPlatform;

  Future<void> pump(
    WidgetTester tester, {
    required _ViewportScenario viewport,
    required double textScale,
    EdgeInsets viewInsets = EdgeInsets.zero,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = viewport.size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final padding = EdgeInsets.fromLTRB(
      (viewport.viewPadding.left - viewInsets.left).clamp(0, double.infinity),
      (viewport.viewPadding.top - viewInsets.top).clamp(0, double.infinity),
      (viewport.viewPadding.right - viewInsets.right).clamp(0, double.infinity),
      (viewport.viewPadding.bottom - viewInsets.bottom).clamp(
        0,
        double.infinity,
      ),
    );
    final mediaQueryData = MediaQueryData(
      size: viewport.size,
      devicePixelRatio: 1,
      textScaler: TextScaler.linear(textScale),
      viewPadding: viewport.viewPadding,
      padding: padding,
      viewInsets: viewInsets,
      systemGestureInsets: viewport.viewPadding,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) =>
              MediaQuery(data: mediaQueryData, child: child!),
          home: StepReviewScreen(recordId: recordId),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }
}

void _expectPinnedPlayer(WidgetTester tester, {required double aspectRatio}) {
  expect(find.byKey(const Key('review-video-player-region')), findsOneWidget);
  expect(find.byKey(const Key('review-video-fallback-region')), findsNothing);
  expect(
    find.ancestor(
      of: find.byKey(const Key('review-video-surface')),
      matching: find.byType(SingleChildScrollView),
    ),
    findsNothing,
  );

  final bodyRect = tester.getRect(find.byKey(const Key('review-body')));
  final visibleFinders = <Finder>[
    find.byKey(const Key('review-video-surface')),
    find.byKey(const Key('review-video-timeline-row')),
    find.byKey(const Key('review-video-slider')),
    find.byKey(const Key('seek-backward-15-seconds')),
    find.byKey(const Key('seek-backward-5-seconds')),
    find.byKey(const Key('toggle-video-playback')),
    find.byKey(const Key('seek-forward-5-seconds')),
    find.byKey(const Key('seek-forward-15-seconds')),
  ];
  for (final finder in visibleFinders) {
    expect(finder, findsOneWidget);
    final rect = tester.getRect(finder);
    expect(
      _containsRect(bodyRect, rect),
      isTrue,
      reason: '$finderの$rectが画面本体$bodyRect内に完全表示されていない',
    );
  }

  final videoSize = tester.getSize(
    find.byKey(const Key('review-video-surface')),
  );
  expect(videoSize.height, greaterThan(0));
  expect(videoSize.width / videoSize.height, closeTo(aspectRatio, 0.001));
  expect(
    tester.getSize(find.byKey(const Key('review-content-region'))).height,
    greaterThanOrEqualTo(96),
  );

  final controlFinders = visibleFinders.sublist(3);
  final controlRects = [
    for (final finder in controlFinders) tester.getRect(finder),
  ];
  for (final rect in controlRects) {
    expect(rect.width, greaterThanOrEqualTo(44));
    expect(rect.height, greaterThanOrEqualTo(44));
    expect(rect.center.dy, closeTo(controlRects.first.center.dy, 0.01));
  }
  for (var index = 1; index < controlRects.length; index++) {
    expect(
      controlRects[index - 1].right,
      lessThanOrEqualTo(controlRects[index].left),
    );
  }
}

Map<Key, Rect> _playerRects(WidgetTester tester) {
  const keys = <Key>[
    Key('review-video-surface'),
    Key('review-video-timeline-row'),
    Key('review-video-slider'),
    Key('seek-backward-15-seconds'),
    Key('seek-backward-5-seconds'),
    Key('toggle-video-playback'),
    Key('seek-forward-5-seconds'),
    Key('seek-forward-15-seconds'),
  ];
  return {for (final key in keys) key: tester.getRect(find.byKey(key))};
}

void _expectRectsUnchanged(WidgetTester tester, Map<Key, Rect> expected) {
  for (final entry in expected.entries) {
    expect(tester.getRect(find.byKey(entry.key)), entry.value);
  }
}

bool _containsRect(Rect outer, Rect inner) {
  const tolerance = 0.01;
  return inner.left >= outer.left - tolerance &&
      inner.top >= outer.top - tolerance &&
      inner.right <= outer.right + tolerance &&
      inner.bottom <= outer.bottom + tolerance;
}

Future<void> _openTab(WidgetTester tester, String label) async {
  final tab = find.widgetWithText(Tab, label);
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

class _ViewportScenario {
  const _ViewportScenario({
    required this.name,
    required this.size,
    required this.viewPadding,
  });

  final String name;
  final Size size;
  final EdgeInsets viewPadding;
}

class _AvailableVideoStorage implements VideoStorageRepository {
  const _AvailableVideoStorage(this.file);

  final File file;

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File?> resolveVideo(String relativePath) async => file;

  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  _FakeVideoPlayerPlatform(this.videoSize);

  final Size videoSize;
  final Map<int, Duration> _positions = {};
  var _nextPlayerId = 1;
  var createCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    createCount++;
    _positions[playerId] = Duration.zero;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream<VideoEvent>.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 2),
      size: videoSize,
    ),
  );

  @override
  Future<void> dispose(int playerId) async {
    _positions.remove(playerId);
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
  Future<Duration> getPosition(int playerId) async =>
      _positions[playerId] ?? Duration.zero;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black, child: SizedBox.expand());
}
