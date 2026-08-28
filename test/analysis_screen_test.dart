import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/analysis_horizontal_axis.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/analysis_screen.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart.dart';
import 'package:cataract_surgery_note/src/features/records/record_detail_screen.dart';
import 'package:cataract_surgery_note/src/features/records/record_list_screen.dart';
import 'package:cataract_surgery_note/src/features/review/step_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/video_import_test_support.dart';

class _NoopVideoStorage implements VideoStorageRepository {
  @override
  Future<void> deleteVideo(String relativePath) async {}

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Never> resolveVideo(String relativePath) async {
    throw UnimplementedError();
  }
}

class _DirectJumpVideoService extends RecordVideoService {
  _DirectJumpVideoService(
    SurgeryRepository repository, {
    required this.videoStateKind,
    this.pendingInspection,
    this.inspectionError,
    this.inspectionHandler,
  }) : super(
         surgeryRepository: repository,
         videoStorageRepository: _NoopVideoStorage(),
         videoImportPreflight: const PassThroughVideoImportPreflight(),
       );

  RecordVideoStateKind videoStateKind;
  final Completer<RecordVideoState>? pendingInspection;
  Object? inspectionError;
  final Future<RecordVideoState> Function(SurgeryRecord record)?
  inspectionHandler;
  int inspectionCount = 0;

  void clearInspectionError() {
    inspectionError = null;
  }

  @override
  Future<RecordVideoState> inspectVideoState(SurgeryRecord record) async {
    inspectionCount++;
    final handler = inspectionHandler;
    if (handler != null) {
      return handler(record);
    }
    final error = inspectionError;
    if (error != null) {
      throw error;
    }
    final pending = pendingInspection;
    if (pending != null) {
      return pending.future;
    }
    return _state();
  }

  RecordVideoState _state() {
    final isAvailable =
        videoStateKind == RecordVideoStateKind.availableManaged ||
        videoStateKind == RecordVideoStateKind.availableLegacy;
    return RecordVideoState(
      videoStateKind,
      file: isAvailable ? File('/tmp/direct-jump-fixture.mp4') : null,
    );
  }
}

class _PreflightRepository extends SurgeryRepository {
  // ignore: use_super_parameters
  _PreflightRepository(
    AppDatabase database, {
    this.recordError,
    this.reviewError,
    this.reviewOverride,
  }) : super(database);

  Object? recordError;
  Object? reviewError;
  final SurgicalStepReview? reviewOverride;

  void clearReadErrors() {
    recordError = null;
    reviewError = null;
  }

  @override
  Future<SurgeryRecord?> getRecord(String id) {
    final error = recordError;
    if (error != null) {
      return Future<SurgeryRecord?>.error(error);
    }
    return super.getRecord(id);
  }

  @override
  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) {
    final error = reviewError;
    if (error != null) {
      return Future<SurgicalStepReview?>.error(error);
    }
    final override = reviewOverride;
    if (override != null) {
      return Future<SurgicalStepReview?>.value(override);
    }
    return super.getStepReview(surgeryRecordId: surgeryRecordId, step: step);
  }
}

class _ControlledAnalysisRepository extends SurgeryRepository {
  // ignore: use_super_parameters
  _ControlledAnalysisRepository(AppDatabase database) : super(database);

  int analysisReadCount = 0;
  Object? _nextAnalysisError;

  void failNextAnalysisRead(Object error) {
    _nextAnalysisError = error;
  }

  @override
  Future<SurgeryAnalysisSnapshot> fetchAnalysisSnapshot() {
    analysisReadCount++;
    final error = _nextAnalysisError;
    _nextAnalysisError = null;
    if (error != null) {
      return Future<SurgeryAnalysisSnapshot>.error(error);
    }
    return super.fetchAnalysisSnapshot();
  }
}

class _AnalysisDirectJumpVideoPlatform extends VideoPlayerPlatform {
  final List<Duration> seekRequests = <Duration>[];
  final Set<int> activePlayerIds = <int>{};
  final Map<int, Duration> _positions = <int, Duration>{};
  var _nextPlayerId = 1;
  var createCount = 0;
  var pauseCount = 0;
  var playCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    createCount++;
    activePlayerIds.add(playerId);
    _positions[playerId] = Duration.zero;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 2),
      size: const Size(1920, 1080),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    activePlayerIds.remove(playerId);
    _positions.remove(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> play(int playerId) async {
    playCount++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCount++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekRequests.add(position);
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

_AnalysisDirectJumpVideoPlatform _installAnalysisVideoPlatform() {
  final platform = _AnalysisDirectJumpVideoPlatform();
  final original = VideoPlayerPlatform.instance;
  VideoPlayerPlatform.instance = platform;
  addTearDown(() => VideoPlayerPlatform.instance = original);
  return platform;
}

void main() {
  SurgeryAnalysisMeasurement measurement({
    required String id,
    required DateTime date,
    SurgicalStep step = SurgicalStep.totalSurgeryTime,
    int start = 0,
    int end = 60000,
    EyeSide eyeSide = EyeSide.right,
  }) {
    return SurgeryAnalysisMeasurement(
      recordId: id,
      surgeryDate: date,
      createdAt: date,
      eyeSide: eyeSide,
      step: step,
      startMilliseconds: start,
      endMilliseconds: end,
    );
  }

  Future<void> pumpAnalysis(
    WidgetTester tester,
    SurgeryAnalysisSnapshot snapshot, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryAnalysisProvider.overrideWith((ref) async => snapshot),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const AnalysisScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<(AppDatabase, SurgeryRepository, SurgeryRecord)> createDirectCase(
    WidgetTester tester, {
    SurgicalStep step = SurgicalStep.capsulorhexis,
    int? startMilliseconds = 1000,
    int? endMilliseconds = 3000,
    String? videoPath,
  }) async {
    late AppDatabase database;
    late SurgeryRepository repository;
    late SurgeryRecord record;
    await tester.runAsync(() async {
      database = AppDatabase.memory();
      repository = SurgeryRepository(database);
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 20),
        eyeSide: EyeSide.right,
      );
      if (videoPath != null) {
        await repository.updateVideoReferenceIfCurrent(
          surgeryRecordId: record.id,
          expectedVideoPath: null,
          videoPath: videoPath,
          videoDisplayName: 'fixture.mp4',
        );
        record = (await repository.getRecord(record.id))!;
      }
      final review = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: step,
      );
      if (startMilliseconds != null && endMilliseconds != null) {
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
          ),
          expectedVideoPath: videoPath,
        );
      }
    });
    addTearDown(database.close);
    return (database, repository, record);
  }

  Future<(AppDatabase, _ControlledAnalysisRepository, List<SurgeryRecord>)>
  createDirectTrendCases(WidgetTester tester, {int count = 3}) async {
    late AppDatabase database;
    late _ControlledAnalysisRepository repository;
    final records = <SurgeryRecord>[];
    await tester.runAsync(() async {
      database = AppDatabase.memory();
      repository = _ControlledAnalysisRepository(database);
      for (var index = 0; index < count; index++) {
        var record = await repository.createRecord(
          surgeryDate: DateTime(2026, 8, 18 + index),
          eyeSide: index.isEven ? EyeSide.right : EyeSide.left,
        );
        final videoPath = 'videos/direct-return/case-$index.mp4';
        await repository.updateVideoReferenceIfCurrent(
          surgeryRecordId: record.id,
          expectedVideoPath: null,
          videoPath: videoPath,
          videoDisplayName: 'case-$index.mp4',
        );
        record = (await repository.getRecord(record.id))!;
        final review = await repository.ensureStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        );
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: 1000,
            endMilliseconds: 1000 + (index + 1) * 2000,
          ),
          expectedVideoPath: videoPath,
        );
        records.add(record);
      }
    });
    addTearDown(database.close);
    return (database, repository, records);
  }

  Map<String, Object?> persistentRecordFields(SurgeryRecord record) {
    return <String, Object?>{
      'id': record.id,
      'surgeryDate': record.surgeryDate.millisecondsSinceEpoch,
      'eyeSide': record.eyeSide.name,
      'reviewStatus': record.reviewStatus.name,
      'reviewSchemaVersion': record.reviewSchemaVersion,
      'videoPath': record.videoPath,
      'videoDisplayName': record.videoDisplayName,
      'caseMemo': record.caseMemo,
      'createdAt': record.createdAt.millisecondsSinceEpoch,
      'updatedAt': record.updatedAt.millisecondsSinceEpoch,
    };
  }

  Map<String, Object?> persistentReviewFields(SurgicalStepReview review) {
    return <String, Object?>{
      'id': review.id,
      'surgeryRecordId': review.surgeryRecordId,
      'step': review.step.storageId,
      'startMilliseconds': review.startMilliseconds,
      'endMilliseconds': review.endMilliseconds,
      'isSkipped': review.isSkipped,
      'rating': review.rating.name,
      'reflection': review.reflection,
      'createdAt': review.createdAt.millisecondsSinceEpoch,
      'updatedAt': review.updatedAt.millisecondsSinceEpoch,
    };
  }

  Future<Map<String, Object?>> capturePersistentSnapshot(
    WidgetTester tester,
    SurgeryRepository repository,
    String recordId,
  ) async {
    late Map<String, Object?> snapshot;
    await tester.runAsync(() async {
      final record = (await repository.getRecord(recordId))!;
      final reviews = <SurgicalStepReview>[];
      for (final step in surgicalStepsInDisplayOrder) {
        final review = await repository.getStepReview(
          surgeryRecordId: recordId,
          step: step,
        );
        if (review != null) {
          reviews.add(review);
        }
      }
      snapshot = <String, Object?>{
        'record': persistentRecordFields(record),
        'reviews': <Map<String, Object?>>[
          for (final review in reviews) persistentReviewFields(review),
        ],
      };
    });
    return snapshot;
  }

  Future<int> countPersistedReviewRows(
    WidgetTester tester,
    AppDatabase database,
    String recordId,
  ) async {
    var count = 0;
    await tester.runAsync(() async {
      final rows = await database
          .customSelect('SELECT surgery_record_id FROM surgical_step_reviews')
          .get();
      count = rows
          .where((row) => row.read<String>('surgery_record_id') == recordId)
          .length;
    });
    return count;
  }

  List<Map<dynamic, dynamic>> observeAccessibilityEvents() {
    final events = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
          message,
        ) async {
          events.add(message as Map<dynamic, dynamic>);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });
    return events;
  }

  Future<void> pumpDatabaseAnalysis(
    WidgetTester tester, {
    required AppDatabase database,
    required SurgeryRepository repository,
    required RecordVideoService videoService,
    SurgeryAnalysisSnapshot? snapshot,
    MediaQueryData? mediaQueryData,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(videoService),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
          if (snapshot != null)
            surgeryAnalysisProvider.overrideWith((ref) async => snapshot),
        ],
        child: MaterialApp(
          home: mediaQueryData == null
              ? const AnalysisScreen()
              : MediaQuery(data: mediaQueryData, child: const AnalysisScreen()),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectMetric(WidgetTester tester, SurgicalStep step) async {
    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    final metric = find.byKey(Key('analysis-metric-${step.storageId}'));
    if (metric.evaluate().isEmpty) {
      await tester.dragUntilVisible(
        metric,
        find.byType(ListView).last,
        const Offset(0, -200),
      );
    } else {
      await tester.ensureVisible(metric);
      await tester.pumpAndSettle();
    }
    await tester.tap(metric);
    await tester.pumpAndSettle();
  }

  Future<void> selectCccMetric(WidgetTester tester) async {
    await selectMetric(tester, SurgicalStep.capsulorhexis);
  }

  Future<void> revealSelectedCardButton(WidgetTester tester) async {
    final button = find.byKey(const Key('analysis-open-selected'));
    await tester.dragUntilVisible(
      button,
      find.byKey(const Key('analysis-content')),
      const Offset(0, -200),
    );
    await tester.pump();
  }

  Future<void> tapSelectedCardButton(WidgetTester tester) async {
    await revealSelectedCardButton(tester);
    final button = find.byKey(const Key('analysis-open-selected'));
    await tester.tap(button);
  }

  Finder trendPaintFinder() => find.descendant(
    of: find.byType(SurgeryTrendChart),
    matching: find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is TrendChartPainter,
    ),
  );

  TrendChartPainter trendPainter(WidgetTester tester) {
    return tester.widget<CustomPaint>(trendPaintFinder()).painter!
        as TrendChartPainter;
  }

  Offset analysisPointCenter(WidgetTester tester, String recordId) {
    final local = trendPainter(tester).layout.points
        .singleWhere((point) => point.point.recordId == recordId)
        .offset;
    return tester.getTopLeft(trendPaintFinder()) + local;
  }

  Future<void> tapAnalysisPoint(WidgetTester tester, String recordId) async {
    final chart = find.byKey(const Key('analysis-chart-interaction'));
    await tester.ensureVisible(chart);
    await tester.pump();
    await tester.tapAt(analysisPointCenter(tester, recordId));
    await tester.pump();
  }

  Future<void> pumpUntilCondition(
    WidgetTester tester,
    bool Function() condition, {
    int maximumPumps = 60,
  }) async {
    for (var attempt = 0; attempt < maximumPumps && !condition(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(condition(), isTrue, reason: '非同期条件が期限内に成立しませんでした。');
  }

  Future<void> openProcessVideoFromSelectedCard(
    WidgetTester tester,
    String recordId,
  ) async {
    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    var point = chart.points.singleWhere(
      (candidate) => candidate.recordId == recordId,
    );
    chart.onPointSelected(point);
    await tester.pump();

    await tapSelectedCardButton(tester);
    await tester.pump();
    await pumpUntilCondition(
      tester,
      () => find
          .byType(StepReviewScreen)
          .evaluate()
          .any((element) => ModalRoute.of(element)?.isCurrent == true),
    );

    expect(
      find
          .byType(StepReviewScreen)
          .evaluate()
          .where((element) => ModalRoute.of(element)?.isCurrent == true),
      hasLength(1),
    );
  }

  testWidgets('症例0件の空状態を表示する', (tester) async {
    await pumpAnalysis(
      tester,
      const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
    );

    expect(find.text('まだ症例がありません'), findsOneWidget);
    expect(find.textContaining('症例を登録すると'), findsOneWidget);
  });

  testWidgets('1件では最新値と点だけを表示して追加記録を案内する', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [measurement(id: 'one', date: DateTime(2026, 7, 20))],
      ),
    );

    expect(find.text('総手術時間'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    expect(find.text('比較できる過去データがありません'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('あと1件記録すると推移を確認できます'), findsOneWidget);
    expect(trendPainter(tester).layout.points.single.point.recordId, 'one');
  });

  testWidgets('指標切り替えでグラフと比較サマリーを更新する', (tester) async {
    final firstDate = DateTime(2026, 7, 19);
    final secondDate = DateTime(2026, 7, 20);
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 2,
        measurements: [
          measurement(id: 'first', date: firstDate, end: 60000),
          measurement(id: 'second', date: secondDate, end: 50000),
          measurement(
            id: 'first',
            date: firstDate,
            step: SurgicalStep.capsulorhexis,
            end: 120000,
          ),
          measurement(
            id: 'second',
            date: secondDate,
            step: SurgicalStep.capsulorhexis,
            end: 90000,
          ),
        ],
      ),
    );

    expect(find.text('0:50'), findsOneWidget);
    expect(find.text('-0:10'), findsOneWidget);

    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('テノン嚢下麻酔'), findsNothing);
    expect(find.text('デキサート結膜下注射'), findsNothing);
    await tester.tap(find.byKey(const Key('analysis-metric-capsulorhexis')));
    await tester.pumpAndSettle();

    expect(find.text('CCC'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget);
    expect(find.text('-0:30'), findsOneWidget);
  });

  testWidgets('点を選択すると完全な日付、左右、時間、詳細導線を表示する', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [
          measurement(
            id: 'selected',
            date: DateTime(2026, 7, 20),
            end: 65000,
            eyeSide: EyeSide.left,
          ),
        ],
      ),
    );

    await tapAnalysisPoint(tester, 'selected');
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('analysis-selected-point')), findsOneWidget);
    expect(find.text('2026年7月20日 左眼'), findsOneWidget);
    expect(find.text('総手術時間：1分05秒'), findsOneWidget);
    expect(find.text('症例詳細を見る'), findsOneWidget);
  });

  testWidgets('個別工程の詳細ボタンは選択中の症例と工程を読み上げる', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [
          measurement(
            id: 'semantic-selected',
            date: DateTime(2026, 7, 20),
            step: SurgicalStep.capsulorhexis,
            end: 65000,
          ),
        ],
      ),
    );
    await selectCccMetric(tester);
    await revealSelectedCardButton(tester);

    final button = tester.getSemantics(
      find.byKey(const Key('analysis-open-selected')),
    );
    expect(button.label, '症例詳細を見る');
    expect(button.hint, contains('2026年7月20日'));
    expect(button.hint, contains('右眼'));
    expect(button.hint, contains('CCCの工程動画'));
    expect(button.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  SurgeryAnalysisSnapshot manyCases(int count) {
    return SurgeryAnalysisSnapshot(
      recordCount: count,
      measurements: [
        for (var index = 0; index < count; index++)
          measurement(
            id: 'c$index',
            date: DateTime(2026, 1, 1).add(Duration(days: index)),
            end: 60000 + index * 1000,
          ),
      ],
    );
  }

  testWidgets('症例が増えても全症例を一画面に表示し横スクロールしない', (tester) async {
    await pumpAnalysis(tester, manyCases(50));

    expect(
      find.descendant(
        of: find.byType(SurgeryTrendChart),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    // 最古と最新の両方が同じplot rectangleへ描画されている。
    final painter = trendPainter(tester);
    expect(
      painter.layout.points.map((point) => point.point.recordId),
      containsAll(['c0', 'c49']),
    );
    expect(painter.layout.points.first.offset.dx, painter.layout.plotLeft);
    expect(painter.layout.points.last.offset.dx, painter.layout.plotRight);
    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('analysis-point-');
      }),
      findsNothing,
    );

    final chart = tester.getRect(find.byType(SurgeryTrendChart));
    final content = tester.getRect(find.byKey(const Key('analysis-content')));
    expect(chart.width, lessThanOrEqualTo(content.width));
  });

  testWidgets('最新症例を初期選択しグラフ全体を1つのadjustable controlとする', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAnalysis(tester, manyCases(3));

    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('症例順 3 / 3'), findsOneWidget);

    final graphFinder = find.byKey(const Key('analysis-trend-adjustable'));
    final graph = tester.getSemantics(graphFinder);
    expect(graph.label, '総手術時間の推移');
    expect(graph.value, contains('この指標3件中3件目'));
    expect(graph.value, contains('2026年1月3日'));
    expect(
      graph.getSemanticsData().hasAction(SemanticsAction.increase),
      isTrue,
    );
    expect(
      graph.getSemanticsData().hasAction(SemanticsAction.decrease),
      isTrue,
    );
    expect(find.bySemanticsLabel('総手術時間の推移'), findsOneWidget);

    graph.owner!.performAction(graph.id, SemanticsAction.decrease);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(graphFinder).value, contains('この指標3件中2件目'));

    final middleGraph = tester.getSemantics(graphFinder);
    middleGraph.owner!.performAction(middleGraph.id, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(graphFinder).value, contains('この指標3件中3件目'));

    final newestGraph = tester.getSemantics(graphFinder);
    newestGraph.owner!.performAction(newestGraph.id, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(tester.getSemantics(graphFinder).value, contains('この指標3件中3件目'));
    semantics.dispose();
  });

  testWidgets('1件のadjustable controlは1/1を読み上げ操作で選択を変えない', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAnalysis(tester, manyCases(1));

    final graphFinder = find.byKey(const Key('analysis-trend-adjustable'));
    final graph = tester.getSemantics(graphFinder);
    expect(graph.value, contains('この指標1件中1件目'));

    for (final action in [SemanticsAction.increase, SemanticsAction.decrease]) {
      graph.owner!.performAction(graph.id, action);
      await tester.pump();
      expect(tester.getSemantics(graphFinder).value, contains('この指標1件中1件目'));
    }
    semantics.dispose();
  });

  testWidgets('データ点の外側をタップしても最寄りの症例が選択される', (tester) async {
    await pumpAnalysis(tester, manyCases(3));

    final graph = find.byKey(const Key('analysis-chart-interaction'));
    await tester.ensureVisible(graph);
    await tester.pump();
    final first = analysisPointCenter(tester, 'c0');
    final middle = analysisPointCenter(tester, 'c1');
    final graphRect = tester.getRect(graph);

    // 点や線から離れたaxis gutterでも、clamp後の最寄り点を選択する。
    await tester.tapAt(Offset((first.dx + middle.dx) / 2, graphRect.top + 1));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.text('症例順 2 / 3'), findsOneWidget);
    expect(find.text('2026年1月2日 右眼'), findsOneWidget);
    expect(find.text('総手術時間：1分01秒'), findsOneWidget);
  });

  testWidgets('前後ボタンで隣接症例へ移動し、両端で無効になる', (tester) async {
    await pumpAnalysis(tester, manyCases(3));

    await tapAnalysisPoint(tester, 'c1');
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('症例順 2 / 3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('analysis-select-previous')));
    await tester.pumpAndSettle();
    expect(find.text('症例順 1 / 3'), findsOneWidget);
    expect(find.text('2026年1月1日 右眼'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('analysis-select-previous')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('analysis-select-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('analysis-select-next')));
    await tester.pumpAndSettle();
    expect(find.text('症例順 3 / 3'), findsOneWidget);
    expect(find.text('2026年1月3日 右眼'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('analysis-select-next')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('指標変更で同じ症例を保持し、値がなければ新指標の最新へ戻る', (tester) async {
    final firstDate = DateTime(2026, 7, 19);
    final secondDate = DateTime(2026, 7, 20);
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 2,
        measurements: [
          measurement(id: 'first', date: firstDate),
          measurement(id: 'second', date: secondDate),
          measurement(
            id: 'first',
            date: firstDate,
            step: SurgicalStep.capsulorhexis,
            end: 80000,
          ),
          measurement(
            id: 'second',
            date: secondDate,
            step: SurgicalStep.capsulorhexis,
            end: 70000,
          ),
          measurement(
            id: 'first',
            date: firstDate,
            step: SurgicalStep.hydrodissection,
            end: 40000,
          ),
        ],
      ),
    );

    expect(
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .value,
      contains('この指標2件中2件目'),
    );

    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('analysis-metric-capsulorhexis')));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .value,
      allOf(contains('この指標2件中2件目'), contains('2026年7月20日')),
    );

    await tester.tap(find.byKey(const Key('analysis-metric-selector')));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.byKey(const Key('analysis-metric-hydrodissection')),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const Key('analysis-metric-hydrodissection')));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .value,
      allOf(contains('この指標1件中1件目'), contains('2026年7月19日')),
    );
  });

  testWidgets('大きな文字でも指標選択と主要情報へアクセスできる', (tester) async {
    await pumpAnalysis(
      tester,
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [
          measurement(id: 'large-text', date: DateTime(2026, 7, 20)),
        ],
      ),
      textScale: 2,
    );

    expect(find.byKey(const Key('analysis-metric-selector')), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('重なった再取得は古い完了結果で新しい選択を上書きしない', (tester) async {
    final semantics = tester.ensureSemantics();
    final olderReload = Completer<SurgeryAnalysisSnapshot>();
    final newerReload = Completer<SurgeryAnalysisSnapshot>();
    var invocation = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryAnalysisProvider.overrideWith((ref) {
            invocation++;
            if (invocation == 1) {
              return Future<SurgeryAnalysisSnapshot>.error(
                StateError('initial failure'),
              );
            }
            return invocation == 2 ? olderReload.future : newerReload.future;
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final retry = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '再読み込み'),
    );
    retry.onPressed!();
    retry.onPressed!();
    newerReload.complete(
      SurgeryAnalysisSnapshot(
        recordCount: 2,
        measurements: [
          measurement(id: 'older', date: DateTime(2026, 8, 1)),
          measurement(id: 'newer', date: DateTime(2026, 8, 2)),
        ],
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .value,
      contains('この指標2件中2件目'),
    );

    olderReload.complete(
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        measurements: [measurement(id: 'older', date: DateTime(2026, 8, 1))],
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .value,
      contains('この指標2件中2件目'),
    );
    semantics.dispose();
  });

  testWidgets('症例一覧AppBarの分析アイコンから分析画面を開く', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryRecordsProvider.overrideWith((ref) async => []),
          surgeryAnalysisProvider.overrideWith(
            (ref) async =>
                const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
          ),
        ],
        child: const MaterialApp(home: RecordListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('分析'), findsOneWidget);
    await tester.tap(find.byTooltip('分析'));
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, '分析'), findsOneWidget);
  });

  testWidgets('選択点から既存の症例詳細画面へ遷移する', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 7, 20),
        eyeSide: EyeSide.right,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
        expectedVideoPath: null,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWith((ref) => database)],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tapAnalysisPoint(tester, record.id);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    final scrollOffsetBeforeOpen = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!
        .offset;
    await tapSelectedCardButton(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('症例詳細'), findsOneWidget);

    await tester.pageBack();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byKey(const Key('analysis-selected-point')), findsOneWidget);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('analysis-content')))
          .controller!
          .offset,
      closeTo(scrollOffsetBeforeOpen, 1),
    );
  });

  testWidgets('push前のscroll snapshotをoffstageのProvider error後も復元する', (
    tester,
  ) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 20),
        eyeSide: EyeSide.right,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
        expectedVideoPath: null,
      );
    });
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [measurement(id: record.id, date: record.surgeryDate)],
    );
    var invocation = 0;
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
          surgeryAnalysisProvider.overrideWith((ref) async {
            invocation++;
            if (invocation == 2) {
              throw StateError('offstage refresh failed');
            }
            return snapshot;
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final analysisContext = tester.element(find.byType(AnalysisScreen));
    final container = ProviderScope.containerOf(analysisContext);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await revealSelectedCardButton(tester);
    final offsetBeforePush = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!
        .offset;
    expect(offsetBeforePush, greaterThan(0));
    await tester.tap(find.byKey(const Key('analysis-open-selected')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);

    container.invalidate(surgeryAnalysisProvider);
    await tester.runAsync(() async {
      try {
        await container.read(surgeryAnalysisProvider.future);
      } on StateError {
        // The forced offstage error is the precondition under test.
      }
    });
    await tester.pumpAndSettle();
    expect(invocation, 2);

    await tester.pageBack();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(invocation, 3);
    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('analysis-content')))
          .controller!
          .offset,
      closeTo(offsetBeforePush, 1),
    );
  });

  testWidgets('再取得成功後は再構築したchartへFocusSemanticEventを送る', (tester) async {
    final semantics = tester.ensureSemantics();
    final refreshed = Completer<SurgeryAnalysisSnapshot>();
    var invocation = 0;
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [
        measurement(id: 'focus-target', date: DateTime(2026, 8, 20)),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryAnalysisProvider.overrideWith((ref) {
            invocation++;
            return invocation == 1
                ? Future<SurgeryAnalysisSnapshot>.error(
                    StateError('initial error'),
                  )
                : refreshed.future;
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final semanticEvents = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
          message,
        ) async {
          semanticEvents.add(message as Map<dynamic, dynamic>);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });

    await tester.tap(find.widgetWithText(FilledButton, '再読み込み'));
    await tester.pump();
    refreshed.complete(snapshot);
    await tester.pumpAndSettle();
    await tester.pump();

    final focusEvents = semanticEvents
        .where((event) => event['type'] == 'focus')
        .toList();
    expect(focusEvents, hasLength(1));
    expect(
      focusEvents.single['nodeId'],
      tester
          .getSemantics(find.byKey(const Key('analysis-trend-adjustable')))
          .id,
    );
    semantics.dispose();
  });

  testWidgets('pull-to-refresh後のR=0とM=0は対応する空状態見出しへfocusする', (tester) async {
    final semantics = tester.ensureSemantics();
    final accessibilityEvents = observeAccessibilityEvents();
    final initial = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [
        measurement(id: 'refresh-focus', date: DateTime(2026, 8, 20)),
      ],
    );
    final cases = <(SurgeryAnalysisSnapshot, String)>[
      (
        const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
        'まだ症例がありません',
      ),
      (
        const SurgeryAnalysisSnapshot(recordCount: 1, measurements: []),
        '「総手術時間」の計測データがありません',
      ),
    ];

    for (final (refreshed, title) in cases) {
      var invocation = 0;
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            surgeryAnalysisProvider.overrideWith((ref) async {
              invocation++;
              return invocation == 1 ? initial : refreshed;
            }),
          ],
          child: const MaterialApp(home: AnalysisScreen()),
        ),
      );
      await tester.pumpAndSettle();
      accessibilityEvents.clear();

      final refreshFuture = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      await tester.runAsync(() => refreshFuture);
      await tester.pumpAndSettle();
      await tester.pump();

      expect(invocation, 2);
      expect(find.byType(SurgeryTrendChart), findsNothing);
      final heading = find
          .ancestor(of: find.text(title), matching: find.byType(Semantics))
          .first;
      final headingNode = tester.getSemantics(heading);
      expect(headingNode.headingLevel, 1);
      expect(
        accessibilityEvents
            .where((event) => event['type'] == 'focus')
            .map((event) => event['nodeId']),
        contains(headingNode.id),
      );
    }
    semantics.dispose();
  });

  testWidgets('詳細画面で症例を削除すると選択点を解除して空状態を表示する', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      final repository = SurgeryRepository(database);
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 7, 20),
        eyeSide: EyeSide.right,
      );
      final total = await repository.ensureStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.totalSurgeryTime,
      );
      await repository.saveStepTiming(
        review: total.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
        expectedVideoPath: null,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tapAnalysisPoint(tester, record.id);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tapSelectedCardButton(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('症例を削除'),
      find.byType(ListView).last,
      const Offset(0, -300),
    );
    await tester.tap(find.text('症例を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byKey(const Key('analysis-selected-point')), findsNothing);
    expect(find.text('まだ症例がありません'), findsOneWidget);
  });

  testWidgets('個別工程の選択操作だけでは動画状態確認とcontroller生成を開始しない', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    final platform = _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );

    void expectNoVideoAccess() {
      expect(service.inspectionCount, 0);
      expect(platform.createCount, 0);
      expect(platform.seekRequests, isEmpty);
      expect(platform.activePlayerIds, isEmpty);
      expect(find.byType(RecordDetailScreen), findsNothing);
      expect(find.byType(StepReviewScreen), findsNothing);
    }

    expectNoVideoAccess();
    await selectCccMetric(tester);
    expectNoVideoAccess();

    await tester.tapAt(analysisPointCenter(tester, records[1].id));
    await tester.pump();
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records[1].id,
    );
    expectNoVideoAccess();

    await tester.tap(find.byKey(const Key('analysis-select-next')));
    await tester.pump();
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records.last.id,
    );
    expectNoVideoAccess();

    await tester.tap(find.byKey(const Key('analysis-select-previous')));
    await tester.pump();
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records[1].id,
    );
    expectNoVideoAccess();

    final graphFinder = find.byKey(const Key('analysis-trend-adjustable'));
    var graph = tester.getSemantics(graphFinder);
    graph.owner!.performAction(graph.id, SemanticsAction.increase);
    await tester.pump();
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records.last.id,
    );
    expectNoVideoAccess();

    graph = tester.getSemantics(graphFinder);
    graph.owner!.performAction(graph.id, SemanticsAction.decrease);
    await tester.pump();
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records[1].id,
    );
    expectNoVideoAccess();

    semantics.dispose();
  });

  testWidgets('unregistered fallbackは症例と全既存工程の永続fieldを変更しない', (tester) async {
    final (database, repository, record) = await createDirectCase(tester);
    await tester.runAsync(() async {
      final reviews = await repository.ensureStepReviews(record.id);
      await repository.saveReviewContent(
        surgeryRecordId: record.id,
        reviews: <SurgicalStepReview>[
          for (var index = 0; index < reviews.length; index++)
            reviews[index].copyWith(
              rating: StepRating
                  .values[(index % (StepRating.values.length - 1)) + 1],
              reflection: 'fallback保持対象 ${reviews[index].step.storageId}',
            ),
        ],
        caseMemo: 'fallbackで変更しない症例メモ',
      );
    });
    final before = await capturePersistentSnapshot(
      tester,
      repository,
      record.id,
    );
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    final after = await capturePersistentSnapshot(
      tester,
      repository,
      record.id,
    );
    expect(after, equals(before));
    expect(tester.takeException(), isNull);
  });

  for (final fallback in <(RecordVideoStateKind, String)>[
    (RecordVideoStateKind.missing, '保存した動画が見つかりません。再登録または差し替えを行ってください。'),
    (RecordVideoStateKind.invalidReference, '動画の参照が無効です。動画を再登録してください。'),
    (RecordVideoStateKind.checkFailed, '動画の状態を確認できませんでした。再確認してください。'),
  ]) {
    testWidgets('${fallback.$1.name}は理由を表示して症例詳細へfallbackする', (tester) async {
      final (database, repository, record) = await createDirectCase(
        tester,
        videoPath: 'videos/direct/fallback.mp4',
      );
      final platform = _installAnalysisVideoPlatform();
      final service = _DirectJumpVideoService(
        repository,
        videoStateKind: fallback.$1,
      );
      await pumpDatabaseAnalysis(
        tester,
        database: database,
        repository: repository,
        videoService: service,
      );
      await selectCccMetric(tester);

      await tapSelectedCardButton(tester);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RecordDetailScreen), findsOneWidget);
      expect(find.text(fallback.$2), findsOneWidget);
      expect(platform.createCount, 0);
      expect(platform.seekRequests, isEmpty);
      expect(platform.activePlayerIds, isEmpty);
    });
  }

  testWidgets('fallback通知はactiveな詳細routeでlive regionとして1回だけ表示し再buildで重複しない', (
    tester,
  ) async {
    const message = 'この症例には動画が登録されていません。';
    final semantics = tester.ensureSemantics();
    final (database, repository, record) = await createDirectCase(tester);
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    final detailContext = tester.element(find.byType(RecordDetailScreen));
    expect(ModalRoute.of(detailContext)?.isCurrent, isTrue);
    expect(find.text(message), findsOneWidget);
    expect(
      tester.getSemantics(find.text(message)),
      matchesSemantics(
        isLiveRegion: true,
        hasDismissAction: true,
        hasScrollDownAction: true,
        hasScrollUpAction: true,
        label: message,
        textDirection: TextDirection.ltr,
      ),
    );
    final container = ProviderScope.containerOf(detailContext);
    container.invalidate(surgeryRecordProvider(record.id));
    container.invalidate(recordVideoStateProvider(record.id));
    container.invalidate(surgeryRecordProgressProvider);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(
      ModalRoute.of(tester.element(find.byType(RecordDetailScreen)))?.isCurrent,
      isTrue,
    );
    expect(find.text(message), findsOneWidget);
    expect(find.bySemanticsLabel(message), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('fallback先は過去の動画Provider cacheを使わず現在の回復UIを表示する', (tester) async {
    final (database, repository, record) = await createDirectCase(
      tester,
      videoPath: 'videos/direct/cache-warm.mp4',
    );
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('アプリ管理動画・利用可能'), findsOneWidget);

    service.videoStateKind = RecordVideoStateKind.missing;
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const AnalysisScreen()),
        );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    await selectCccMetric(tester);
    await tapSelectedCardButton(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.textContaining('保存した動画の実体が見つかりません'), findsOneWidget);
    expect(find.text('同じ動画を再登録'), findsOneWidget);
    expect(find.text('別の動画に差し替え'), findsOneWidget);
    expect(service.inspectionCount, greaterThanOrEqualTo(3));
  });

  testWidgets('工程位置fallback先は過去の進捗cacheを使わない', (tester) async {
    final (database, repository, record) = await createDirectCase(tester);
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
        ],
        child: MaterialApp(home: RecordDetailScreen(recordId: record.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('工程 1/10'), findsOneWidget);

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const AnalysisScreen()),
        );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    await selectCccMetric(tester);
    await tester.runAsync(() async {
      final review = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(clearStart: true, clearEnd: true),
        expectedVideoPath: null,
      );
    });
    await tapSelectedCardButton(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('この工程の記録位置を取得できませんでした。'), findsOneWidget);
    expect(find.text('未記録'), findsOneWidget);
    expect(find.text('工程 1/10'), findsNothing);
    // warm-upとfallback先の状態カード各1回。Analysisの遷移前確認は、
    // 工程位置欠落が確定したため追加の動画確認を開始しない。
    expect(service.inspectionCount, 2);
  });

  testWidgets('利用可能な動画では対象工程intent付きで工程レビューを直接開く', (tester) async {
    final (database, repository, record) = await createDirectCase(
      tester,
      videoPath: 'videos/direct/fixture.mp4',
    );
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    final review = tester.widget<StepReviewScreen>(
      find.byType(StepReviewScreen),
    );
    expect(review.recordId, record.id);
    expect(review.initialStepStorageId, SurgicalStep.capsulorhexis.storageId);
  });

  testWidgets('表示点tapから実StepReviewのCCC開始位置へ一度だけpaused seekする', (tester) async {
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    final platform = _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    final staleChart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(
      staleChart.points
          .singleWhere((point) => point.recordId == records.last.id)
          .duration,
      const Duration(seconds: 6),
    );
    await tester.runAsync(() async {
      final latestReview = (await repository.getStepReview(
        surgeryRecordId: records.last.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: latestReview.copyWith(startMilliseconds: 2500),
        expectedVideoPath: records.last.videoPath,
      );
    });
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .points
          .singleWhere((point) => point.recordId == records.last.id)
          .duration,
      const Duration(seconds: 6),
      reason: '活性化前のグラフは再取得せず旧値を保持する',
    );

    await tapSelectedCardButton(tester);
    await tester.pump();
    await pumpUntilCondition(
      tester,
      () =>
          platform.seekRequests.length == 1 &&
          find.text('CCCの開始位置へ移動しました').evaluate().isNotEmpty,
    );

    final destination = tester.widget<StepReviewScreen>(
      find.byType(StepReviewScreen),
    );
    expect(destination.recordId, records.last.id);
    expect(
      destination.initialStepStorageId,
      SurgicalStep.capsulorhexis.storageId,
    );
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(
      tabBar.controller!.index,
      surgicalStepsInDisplayOrder.indexOf(SurgicalStep.capsulorhexis),
    );
    expect(platform.createCount, 1);
    expect(platform.seekRequests, <Duration>[
      const Duration(milliseconds: 2500),
    ]);
    expect(platform.pauseCount, greaterThanOrEqualTo(1));
    expect(platform.playCount, 0);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct reviewから戻ると分析を再取得し工程・症例・scrollを保持する', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final accessibilityEvents = observeAccessibilityEvents();
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    expect(repository.analysisReadCount, 1);
    await selectCccMetric(tester);

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    final selectedPoint = chart.points.singleWhere(
      (point) => point.recordId == records[1].id,
    );
    chart.onPointSelected(selectedPoint);
    await tester.pump();
    final scrollController = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!;
    scrollController.jumpTo(
      scrollController.position.maxScrollExtent.clamp(0.0, 120.0).toDouble(),
    );
    await tester.pump();
    await revealSelectedCardButton(tester);
    final scrollOffsetBeforeOpen = scrollController.offset;
    expect(scrollOffsetBeforeOpen, greaterThan(0));

    await openProcessVideoFromSelectedCard(tester, records[1].id);
    expect(repository.analysisReadCount, 1);
    final accessibilityEventCountBeforeReturn = accessibilityEvents.length;
    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 2 &&
          find.byType(SurgeryTrendChart).evaluate().isNotEmpty,
    );
    await tester.pump();

    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.points.first.step, SurgicalStep.capsulorhexis);
    expect(chart.selectedRecordId, records[1].id);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('analysis-content')))
          .controller!
          .offset,
      closeTo(scrollOffsetBeforeOpen, 1),
    );
    expect(repository.analysisReadCount, 2);
    final graphNode = tester.getSemantics(
      find.byKey(const Key('analysis-trend-adjustable')),
    );
    expect(
      accessibilityEvents
          .skip(accessibilityEventCountBeforeReturn)
          .where((event) => event['type'] == 'focus')
          .map((event) => event['nodeId']),
      contains(graphNode.id),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('direct review復帰で内容が短縮したらscrollを新しい最大値へclampする', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (database, repository, records) = await createDirectTrendCases(
      tester,
      count: 1,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    final scrollController = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!;
    final previousMaximum = scrollController.position.maxScrollExtent;
    expect(previousMaximum, greaterThan(0));
    expect(
      tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart)).points,
      hasLength(1),
    );
    scrollController.jumpTo(previousMaximum);
    await tester.pump();

    await tapSelectedCardButton(tester);
    await tester.pump();
    await pumpUntilCondition(
      tester,
      () => find
          .byType(StepReviewScreen)
          .evaluate()
          .any((element) => ModalRoute.of(element)?.isCurrent == true),
    );
    await tester.runAsync(() async {
      var addedRecord = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 21),
        eyeSide: EyeSide.left,
      );
      const addedVideoPath = 'videos/direct-return/shorter-content.mp4';
      await repository.updateVideoReferenceIfCurrent(
        surgeryRecordId: addedRecord.id,
        expectedVideoPath: null,
        videoPath: addedVideoPath,
        videoDisplayName: 'shorter-content.mp4',
      );
      addedRecord = (await repository.getRecord(addedRecord.id))!;
      final addedReview = await repository.ensureStepReview(
        surgeryRecordId: addedRecord.id,
        step: SurgicalStep.capsulorhexis,
      );
      await repository.saveStepTiming(
        review: addedReview.copyWith(
          startMilliseconds: 1000,
          endMilliseconds: 5000,
        ),
        expectedVideoPath: addedRecord.videoPath,
      );
    });

    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 2 &&
          find.byType(SurgeryTrendChart).evaluate().isNotEmpty,
    );
    await tester.pump();
    await tester.pump();

    final restoredController = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!;
    final newMaximum = restoredController.position.maxScrollExtent;
    expect(
      tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart)).points,
      hasLength(2),
    );
    expect(newMaximum, lessThan(previousMaximum));
    expect(restoredController.offset, closeTo(newMaximum, 1));
    expect(
      tester
          .widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart))
          .selectedRecordId,
      records.single.id,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct review中の工程時刻変更を復帰後のグラフと平均へ反映する', (tester) async {
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);
    expect(find.text('0:06'), findsOneWidget);
    expect(find.text('0:03'), findsOneWidget);
    expect(find.text('+0:03'), findsOneWidget);

    await openProcessVideoFromSelectedCard(tester, records.last.id);
    await tester.runAsync(() async {
      final review = (await repository.getStepReview(
        surgeryRecordId: records.last.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(startMilliseconds: 1000, endMilliseconds: 2000),
        expectedVideoPath: records.last.videoPath,
      );
    });
    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 2 &&
          find.byType(SurgeryTrendChart).evaluate().isNotEmpty,
    );
    await tester.pump();

    final chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(chart.selectedRecordId, records.last.id);
    expect(
      chart.points
          .singleWhere((point) => point.recordId == records.last.id)
          .duration,
      const Duration(seconds: 1),
    );
    tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!
        .jumpTo(0);
    await tester.pump();
    expect(find.text('0:01'), findsOneWidget);
    expect(find.text('0:03'), findsOneWidget);
    expect(find.text('-0:02'), findsOneWidget);
    expect(find.text('2秒短縮'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct対象点が消えた復帰では最新の有効点を選択する', (tester) async {
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);
    await openProcessVideoFromSelectedCard(tester, records.last.id);

    await tester.runAsync(() async {
      final review = (await repository.getStepReview(
        surgeryRecordId: records.last.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(clearStart: true, clearEnd: true),
        expectedVideoPath: records.last.videoPath,
      );
    });
    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 2 &&
          find.byType(SurgeryTrendChart).evaluate().isNotEmpty,
    );
    await tester.pump();

    final chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(
      chart.points.map((point) => point.recordId),
      isNot(contains(records.last.id)),
    );
    expect(chart.points.last.recordId, records[1].id);
    expect(chart.selectedRecordId, records[1].id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct対象指標が0件になった復帰で空状態見出しへfocusする', (tester) async {
    final semantics = tester.ensureSemantics();
    final accessibilityEvents = observeAccessibilityEvents();
    final (database, repository, records) = await createDirectTrendCases(
      tester,
      count: 1,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);
    await openProcessVideoFromSelectedCard(tester, records.single.id);

    await tester.runAsync(() async {
      final review = (await repository.getStepReview(
        surgeryRecordId: records.single.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(clearStart: true, clearEnd: true),
        expectedVideoPath: records.single.videoPath,
      );
    });
    final accessibilityEventCountBeforeReturn = accessibilityEvents.length;
    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 2 &&
          find.text('「CCC」の計測データがありません').evaluate().isNotEmpty,
    );
    await tester.pump();

    expect(find.byType(SurgeryTrendChart), findsNothing);
    expect(find.byKey(const Key('analysis-selected-point')), findsNothing);
    final emptyHeading = find
        .ancestor(
          of: find.text('「CCC」の計測データがありません'),
          matching: find.byType(Semantics),
        )
        .first;
    expect(emptyHeading, findsOneWidget);
    final emptyHeadingNode = tester.getSemantics(emptyHeading);
    expect(emptyHeadingNode.headingLevel, 1);
    expect(
      accessibilityEvents
          .skip(accessibilityEventCountBeforeReturn)
          .where((event) => event['type'] == 'focus')
          .map((event) => event['nodeId']),
      contains(emptyHeadingNode.id),
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('direct復帰reload失敗後の再試行で症例・scrollを復元する', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (database, repository, records) = await createDirectTrendCases(
      tester,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    final selectedPoint = chart.points.singleWhere(
      (point) => point.recordId == records[1].id,
    );
    chart.onPointSelected(selectedPoint);
    await tester.pump();
    final scrollController = tester
        .widget<ListView>(find.byKey(const Key('analysis-content')))
        .controller!;
    scrollController.jumpTo(
      scrollController.position.maxScrollExtent.clamp(0.0, 120.0).toDouble(),
    );
    await tester.pump();
    await revealSelectedCardButton(tester);
    final scrollOffsetBeforeOpen = scrollController.offset;
    expect(scrollOffsetBeforeOpen, greaterThan(0));
    await openProcessVideoFromSelectedCard(tester, records[1].id);

    repository.failNextAnalysisRead(StateError('制御可能な復帰reload失敗'));
    await tester.pageBack();
    await pumpUntilCondition(
      tester,
      () => find.text('分析データを読み込めませんでした').evaluate().isNotEmpty,
    );
    expect(repository.analysisReadCount, 2);

    await tester.tap(find.widgetWithText(FilledButton, '再読み込み'));
    await pumpUntilCondition(
      tester,
      () =>
          repository.analysisReadCount == 3 &&
          find.byType(SurgeryTrendChart).evaluate().isNotEmpty,
    );
    await tester.pump();

    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.points.first.step, SurgicalStep.capsulorhexis);
    expect(chart.selectedRecordId, records[1].id);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('analysis-content')))
          .controller!
          .offset,
      closeTo(scrollOffsetBeforeOpen, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('全10個別工程がrecordIdと固有storageIdを保って工程レビューを直接開く', (tester) async {
    expect(activeIndividualSurgicalSteps, hasLength(10));
    expect(
      activeIndividualSurgicalSteps.where(
        (step) => step.label.startsWith('I/A'),
      ),
      hasLength(2),
    );

    for (var index = 0; index < activeIndividualSurgicalSteps.length; index++) {
      if (index > 0) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
      final step = activeIndividualSurgicalSteps[index];
      final (database, repository, record) = await createDirectCase(
        tester,
        step: step,
        videoPath: 'videos/direct/${step.storageId}.mp4',
      );
      final service = _DirectJumpVideoService(
        repository,
        videoStateKind: RecordVideoStateKind.availableManaged,
      );
      await pumpDatabaseAnalysis(
        tester,
        database: database,
        repository: repository,
        videoService: service,
      );
      await selectMetric(tester, step);

      await tapSelectedCardButton(tester);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      final destination = tester.widget<StepReviewScreen>(
        find.byType(StepReviewScreen),
      );
      expect(destination.recordId, record.id, reason: step.storageId);
      expect(
        destination.initialStepStorageId,
        step.storageId,
        reason: step.storageId,
      );
      expect(find.byType(RecordDetailScreen), findsNothing);
    }
  });

  testWidgets('複数症例でも活性化した点のrecordIdを別症例と取り違えない', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final records = <SurgeryRecord>[];
    await tester.runAsync(() async {
      for (var index = 0; index < 2; index++) {
        var record = await repository.createRecord(
          surgeryDate: DateTime(2026, 8, 19 + index),
          eyeSide: index == 0 ? EyeSide.left : EyeSide.right,
        );
        final videoPath = 'videos/direct/case-$index.mp4';
        await repository.updateVideoReferenceIfCurrent(
          surgeryRecordId: record.id,
          expectedVideoPath: null,
          videoPath: videoPath,
          videoDisplayName: 'case-$index.mp4',
        );
        record = (await repository.getRecord(record.id))!;
        final review = await repository.ensureStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        );
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: 1000 + index * 1000,
            endMilliseconds: 3000 + index * 1000,
          ),
          expectedVideoPath: videoPath,
        );
        records.add(record);
      }
    });
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    for (final record in records) {
      final chart = tester.widget<SurgeryTrendChart>(
        find.byType(SurgeryTrendChart),
      );
      chart.onPointSelected(
        chart.points.singleWhere((point) => point.recordId == record.id),
      );
      await tester.pump();
      await tapSelectedCardButton(tester);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();

      final destination = tester.widget<StepReviewScreen>(
        find.byType(StepReviewScreen),
      );
      expect(destination.recordId, record.id);
      expect(
        destination.initialStepStorageId,
        SurgicalStep.capsulorhexis.storageId,
      );

      if (record != records.last) {
        await tester.pageBack();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('availableLegacyも対象工程intent付きで工程レビューを直接開く', (tester) async {
    final (database, repository, record) = await createDirectCase(
      tester,
      videoPath: '/external/direct-legacy.mp4',
    );
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableLegacy,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    final review = tester.widget<StepReviewScreen>(
      find.byType(StepReviewScreen),
    );
    expect(review.recordId, record.id);
    expect(review.initialStepStorageId, SurgicalStep.capsulorhexis.storageId);
  });

  testWidgets('記録位置がfresh readで消失していれば症例詳細へ安全にfallbackする', (tester) async {
    final (database, repository, record) = await createDirectCase(
      tester,
      startMilliseconds: null,
      endMilliseconds: null,
    );
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [
        measurement(
          id: record.id,
          date: record.surgeryDate,
          step: SurgicalStep.capsulorhexis,
          start: 1000,
          end: 3000,
        ),
      ],
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
      snapshot: snapshot,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('この工程の記録位置を取得できませんでした。'), findsOneWidget);
  });

  for (final failure in <(String, bool)>[('症例read', true), ('工程read', false)]) {
    testWidgets('${failure.$1}例外は分析画面に留まり再試行できる', (tester) async {
      final (database, _, record) = await createDirectCase(
        tester,
        videoPath: 'videos/direct/read-error.mp4',
      );
      final repository = _PreflightRepository(
        database,
        recordError: failure.$2 ? StateError('record read failed') : null,
        reviewError: failure.$2 ? null : StateError('review read failed'),
      );
      _installAnalysisVideoPlatform();
      final service = _DirectJumpVideoService(
        repository,
        videoStateKind: RecordVideoStateKind.availableManaged,
      );
      await pumpDatabaseAnalysis(
        tester,
        database: database,
        repository: repository,
        videoService: service,
      );
      await selectCccMetric(tester);

      await tapSelectedCardButton(tester);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AnalysisScreen), findsOneWidget);
      expect(find.byType(RecordDetailScreen), findsNothing);
      expect(find.byType(StepReviewScreen), findsNothing);
      expect(find.text('症例を確認できませんでした。もう一度お試しください。'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
      expect(service.inspectionCount, 0);

      repository.clearReadErrors();
      await tester.tap(find.text('再試行'));
      await tester.pump();
      await pumpUntilCondition(
        tester,
        () => find
            .byType(StepReviewScreen)
            .evaluate()
            .any((element) => ModalRoute.of(element)?.isCurrent == true),
      );

      final destination = tester.widget<StepReviewScreen>(
        find.byType(StepReviewScreen),
      );
      expect(destination.recordId, record.id);
      expect(
        destination.initialStepStorageId,
        SurgicalStep.capsulorhexis.storageId,
      );
      expect(find.byType(RecordDetailScreen), findsNothing);
      expect(service.inspectionCount, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('工程rowが存在しない場合は動画確認せず症例詳細へfallbackする', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    late SurgeryRecord record;
    await tester.runAsync(() async {
      record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 20),
        eyeSide: EyeSide.right,
      );
      await database.customStatement(
        'DELETE FROM surgical_step_reviews WHERE surgery_record_id = ?',
        <Object?>[record.id],
      );
    });
    expect(await countPersistedReviewRows(tester, database, record.id), 0);
    final detailInspection = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
      pendingInspection: detailInspection,
    );
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [
        measurement(
          id: record.id,
          date: record.surgeryDate,
          step: SurgicalStep.capsulorhexis,
          start: 1000,
          end: 3000,
        ),
      ],
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
      snapshot: snapshot,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    // The sole inspection belongs to the already-open fallback detail screen.
    // A preflight inspection would leave Analysis current on this completer.
    expect(service.inspectionCount, 1);
    detailInspection.complete(
      const RecordVideoState(RecordVideoStateKind.unregistered),
    );
    await tester.pumpAndSettle();
    expect(find.text('この工程の記録位置を取得できませんでした。'), findsOneWidget);
    expect(await countPersistedReviewRows(tester, database, record.id), 0);
  });

  testWidgets('負の工程開始位置は動画確認せず症例詳細へfallbackする', (tester) async {
    final (database, baseRepository, record) = await createDirectCase(
      tester,
      videoPath: 'videos/direct/negative-start.mp4',
    );
    late SurgicalStepReview invalidReview;
    await tester.runAsync(() async {
      invalidReview = (await baseRepository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!.copyWith(startMilliseconds: -1);
    });
    final repository = _PreflightRepository(
      database,
      reviewOverride: invalidReview,
    );
    final detailInspection = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
      pendingInspection: detailInspection,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(service.inspectionCount, 1);
    detailInspection.complete(
      const RecordVideoState(RecordVideoStateKind.unregistered),
    );
    await tester.pumpAndSettle();
    expect(find.text('この工程の記録位置を取得できませんでした。'), findsOneWidget);
  });

  testWidgets('遅延中はbusyを示して連打を1件にまとめる', (tester) async {
    final semantics = tester.ensureSemantics();
    final (database, repository, record) = await createDirectCase(tester);
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
      pendingInspection: pending,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    final button = find.byKey(const Key('analysis-open-selected'));
    await tapSelectedCardButton(tester);
    await tester.pump();
    // The preflight is still pending, so busy must be present on the first
    // frame after activation rather than one frame later.
    final busy = find.byKey(const Key('analysis-direct-jump-busy'));
    expect(busy, findsOneWidget);
    expect(tester.getSemantics(busy).label, '工程動画を確認しています');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(service.inspectionCount, 1);

    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(service.inspectionCount, 1);

    pending.complete(const RecordVideoState(RecordVideoStateKind.unregistered));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('busy中は症例・指標・空白・前後・詳細・Semantics・更新操作を全て固定する', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final records = <SurgeryRecord>[];
    await tester.runAsync(() async {
      for (var index = 0; index < 2; index++) {
        final record = await repository.createRecord(
          surgeryDate: DateTime(2026, 8, 19 + index),
          eyeSide: index == 0 ? EyeSide.left : EyeSide.right,
        );
        final review = await repository.ensureStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        );
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: 1000 + index * 100,
            endMilliseconds: 3000 + index * 200,
          ),
          expectedVideoPath: null,
        );
        records.add(record);
      }
    });
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: records.length,
      measurements: [
        for (var index = 0; index < records.length; index++)
          measurement(
            id: records[index].id,
            date: records[index].surgeryDate,
            eyeSide: records[index].eyeSide,
            step: SurgicalStep.capsulorhexis,
            start: 1000 + index * 100,
            end: 3000 + index * 200,
          ),
      ],
    );
    var analysisReadCount = 0;
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
      pendingInspection: pending,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
          surgeryAnalysisProvider.overrideWith((ref) async {
            analysisReadCount++;
            return snapshot;
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await selectCccMetric(tester);

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    chart.onPointSelected(chart.points.first);
    await tester.pump();
    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.selectedRecordId, records.first.id);

    final staleChart = chart;
    final staleGraphSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(const Key('analysis-trend-adjustable')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    final staleNext = tester
        .widget<IconButton>(find.byKey(const Key('analysis-select-next')))
        .onPressed;
    final staleOpenDetails = tester
        .widget<FilledButton>(
          find
              .ancestor(
                of: find.text('症例詳細を見る'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              )
              .first,
        )
        .onPressed;
    final staleMetricPicker = tester
        .widget<ListTile>(find.byKey(const Key('analysis-metric-selector')))
        .onTap;
    final staleRefresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh;

    // Start the first button activation and exercise callbacks from the still-mounted
    // old widget tree before a pump can rebuild it with enabled=false.
    staleOpenDetails?.call();
    staleChart.onPointSelected(staleChart.points.last);
    staleGraphSemantics.properties.onIncrease?.call();
    staleNext?.call();
    staleOpenDetails?.call();
    staleMetricPicker?.call();
    unawaited(staleRefresh());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(service.inspectionCount, 1);
    expect(find.byKey(const Key('analysis-direct-jump-busy')), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('analysis-open-selected')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const Key('analysis-metric-selector')),
      warnIfMissed: false,
    );
    await tester.tapAt(analysisPointCenter(tester, records.last.id));
    await tester.tap(
      find.byKey(const Key('analysis-select-previous')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const Key('analysis-select-next')),
      warnIfMissed: false,
    );
    await tester.tap(find.text('症例詳細を見る'), warnIfMissed: false);
    await tester.drag(
      find.byKey(const Key('analysis-content')),
      const Offset(0, 300),
      warnIfMissed: false,
    );
    await tester.pump();

    final metricSelector = tester.widget<ListTile>(
      find.byKey(const Key('analysis-metric-selector')),
    );
    expect(metricSelector.onTap, isNull);
    expect(
      tester
          .widget<SegmentedButton<AnalysisHorizontalAxisMode>>(
            find.byKey(const Key('analysis-horizontal-axis-selector')),
          )
          .onSelectionChanged,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('analysis-horizontal-axis-help')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('analysis-select-previous')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('analysis-select-next')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find
                .ancestor(
                  of: find.text('症例詳細を見る'),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is FilledButton,
                  ),
                )
                .first,
          )
          .onPressed,
      isNull,
    );
    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.selectedRecordId, records.first.id);
    expect(chart.enabled, isFalse);
    final graphSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(const Key('analysis-trend-adjustable')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(graphSemantics.properties.value, contains('2026年8月19日'));
    expect(graphSemantics.properties.onIncrease, isNull);
    expect(graphSemantics.properties.onDecrease, isNull);
    expect(graphSemantics.properties.onTap, isNull);
    expect(find.bySemanticsLabel('工程動画を確認しています'), findsOneWidget);
    expect(service.inspectionCount, 1);
    expect(analysisReadCount, 1);
    expect(
      find
          .byType(RecordDetailScreen)
          .evaluate()
          .where((element) => ModalRoute.of(element)?.isCurrent == true),
      isEmpty,
    );
    expect(find.byType(StepReviewScreen), findsNothing);

    pending.complete(const RecordVideoState(RecordVideoStateKind.unregistered));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('モーション無効時のbusyは回転indicatorを静止iconへ置き換える', (tester) async {
    final (database, repository, record) = await createDirectCase(tester);
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
      pendingInspection: pending,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
      mediaQueryData: const MediaQueryData(disableAnimations: true),
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    final busy = find.byKey(const Key('analysis-direct-jump-busy'));
    expect(busy, findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(
      find.descendant(
        of: busy,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const Key('analysis-direct-jump-busy-static-icon')),
      findsOneWidget,
    );

    pending.complete(const RecordVideoState(RecordVideoStateKind.unregistered));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('確認中に戻った場合はpop遷移中の遅延完了から別routeを開かない', (tester) async {
    final (database, repository, record) = await createDirectCase(tester);
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
      pendingInspection: pending,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AnalysisScreen(),
                    ),
                  ),
                  child: const Text('分析を開く'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('分析を開く'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    await selectCccMetric(tester);
    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(find.byKey(const Key('analysis-direct-jump-busy')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    pending.complete(const RecordVideoState(RecordVideoStateKind.unregistered));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.text('分析を開く'), findsOneWidget);
    expect(find.byType(AnalysisScreen), findsNothing);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(find.byType(StepReviewScreen), findsNothing);
    expect(find.text('この症例には動画が登録されていません。'), findsNothing);
  });

  testWidgets('復帰reload中の新directは古い完了結果から選択snapshotとfocusを変更されない', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final records = <SurgeryRecord>[];
    await tester.runAsync(() async {
      for (var index = 0; index < 2; index++) {
        final record = await repository.createRecord(
          surgeryDate: DateTime(2026, 8, 19 + index),
          eyeSide: index == 0 ? EyeSide.left : EyeSide.right,
        );
        final review = await repository.ensureStepReview(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
        );
        await repository.saveStepTiming(
          review: review.copyWith(
            startMilliseconds: 1000 + index * 100,
            endMilliseconds: 3000 + index * 200,
          ),
          expectedVideoPath: null,
        );
        records.add(record);
      }
    });
    final initialSnapshot = SurgeryAnalysisSnapshot(
      recordCount: 2,
      measurements: [
        for (var index = 0; index < records.length; index++)
          measurement(
            id: records[index].id,
            date: records[index].surgeryDate,
            eyeSide: records[index].eyeSide,
            step: SurgicalStep.capsulorhexis,
            start: 1000 + index * 100,
            end: 3000 + index * 200,
          ),
      ],
    );
    final reloadedSnapshot = SurgeryAnalysisSnapshot(
      recordCount: 2,
      measurements: [initialSnapshot.measurements.first],
    );
    final returnReload = Completer<SurgeryAnalysisSnapshot>();
    final secondDirectInspection = Completer<RecordVideoState>();
    var analysisInvocation = 0;
    var secondRecordInspectionCount = 0;
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.unregistered,
      inspectionHandler: (record) {
        if (record.id == records.last.id) {
          secondRecordInspectionCount++;
          return secondDirectInspection.future;
        }
        return Future<RecordVideoState>.value(
          const RecordVideoState(RecordVideoStateKind.unregistered),
        );
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          surgeryRepositoryProvider.overrideWithValue(repository),
          recordVideoServiceProvider.overrideWithValue(service),
          videoStorageRepositoryProvider.overrideWithValue(_NoopVideoStorage()),
          surgeryAnalysisProvider.overrideWith((ref) {
            analysisInvocation++;
            return analysisInvocation == 1
                ? Future<SurgeryAnalysisSnapshot>.value(initialSnapshot)
                : returnReload.future;
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await selectCccMetric(tester);

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    chart.onPointSelected(chart.points.first);
    await tester.pump();
    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);

    final semanticEvents = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
          message,
        ) async {
          semanticEvents.add(message as Map<dynamic, dynamic>);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 350));
    expect(analysisInvocation, 2);
    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(
      chart.points.map((point) => point.recordId),
      contains(records.last.id),
    );
    chart.onPointSelected(
      chart.points.singleWhere((point) => point.recordId == records.last.id),
    );
    await tester.pump();
    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    expect(secondRecordInspectionCount, 1);
    expect(find.byKey(const Key('analysis-direct-jump-busy')), findsOneWidget);

    returnReload.complete(reloadedSnapshot);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.selectedRecordId, records.last.id);
    final graphSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byKey(const Key('analysis-trend-adjustable')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(graphSemantics.properties.value, contains('2026年8月20日'));
    expect(semanticEvents.where((event) => event['type'] == 'focus'), isEmpty);
    expect(
      find
          .byType(RecordDetailScreen)
          .evaluate()
          .where((element) => ModalRoute.of(element)?.isCurrent == true),
      isEmpty,
    );
    expect(find.byType(StepReviewScreen), findsNothing);

    secondDirectInspection.complete(
      const RecordVideoState(RecordVideoStateKind.unregistered),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RecordDetailScreen), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('動画確認失敗後に選択を変えた再試行は現在の症例を開く', (tester) async {
    final (database, repository, records) = await createDirectTrendCases(
      tester,
      count: 2,
    );
    _installAnalysisVideoPlatform();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.checkFailed,
      inspectionError: StateError('inspection failed'),
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);
    final chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    chart.onPointSelected(
      chart.points.singleWhere((point) => point.recordId == records.first.id),
    );
    await tester.pump();

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(find.text('動画の状態を確認できませんでした。もう一度お試しください。'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(service.inspectionCount, 1);

    await tester.tap(find.byKey(const Key('analysis-select-next')));
    await tester.pump();
    expect(find.text('症例順 2 / 2'), findsOneWidget);

    service.clearInspectionError();
    service.videoStateKind = RecordVideoStateKind.availableManaged;
    await tester.tap(find.text('再試行'));
    await tester.pump();
    await pumpUntilCondition(
      tester,
      () => find
          .byType(StepReviewScreen)
          .evaluate()
          .any((element) => ModalRoute.of(element)?.isCurrent == true),
    );

    final destination = tester.widget<StepReviewScreen>(
      find.byType(StepReviewScreen),
    );
    expect(destination.recordId, records.last.id);
    expect(
      destination.initialStepStorageId,
      SurgicalStep.capsulorhexis.storageId,
    );
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(service.inspectionCount, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('動画状態確認中に症例が削除されたら古い完了結果で画面を開かない', (tester) async {
    final semantics = tester.ensureSemantics();
    final (database, repository, record) = await createDirectCase(tester);
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
      pendingInspection: pending,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    final semanticEvents = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
          message,
        ) async {
          semanticEvents.add(message as Map<dynamic, dynamic>);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(() => repository.deleteRecord(record.id));
    pending.complete(
      const RecordVideoState(RecordVideoStateKind.availableManaged),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byType(StepReviewScreen), findsNothing);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(find.text('症例が見つかりませんでした。'), findsOneWidget);
    final emptyState = find.bySemanticsLabel('まだ症例がありません');
    expect(emptyState, findsOneWidget);
    final emptyStateNode = tester.getSemantics(emptyState);
    expect(emptyStateNode.headingLevel, 1);
    final focusEvents = semanticEvents
        .where((event) => event['type'] == 'focus')
        .toList();
    expect(focusEvents, hasLength(1));
    expect(focusEvents.single['nodeId'], emptyStateNode.id);
    expect(service.inspectionCount, 1);
    semantics.dispose();
  });

  testWidgets('動画状態確認中に参照が変わったら古い判定を破棄して再試行を案内する', (tester) async {
    const originalPath = 'videos/direct/original.mp4';
    final (database, repository, record) = await createDirectCase(
      tester,
      videoPath: originalPath,
    );
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
      pendingInspection: pending,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => repository.updateVideoReferenceIfCurrent(
        surgeryRecordId: record.id,
        expectedVideoPath: originalPath,
        videoPath: 'videos/direct/replaced.mp4',
        videoDisplayName: 'replaced.mp4',
      ),
    );
    pending.complete(
      const RecordVideoState(RecordVideoStateKind.availableManaged),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byType(StepReviewScreen), findsNothing);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(find.text('動画が更新されました。もう一度お試しください。'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(service.inspectionCount, 1);
  });

  testWidgets('動画確認中に工程位置と参照が同時変更されたら工程位置fallbackを優先する', (tester) async {
    const originalPath = 'videos/direct/composite-original.mp4';
    final (database, repository, record) = await createDirectCase(
      tester,
      videoPath: originalPath,
    );
    final pending = Completer<RecordVideoState>();
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
      pendingInspection: pending,
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(() async {
      final review = (await repository.getStepReview(
        surgeryRecordId: record.id,
        step: SurgicalStep.capsulorhexis,
      ))!;
      await repository.saveStepTiming(
        review: review.copyWith(clearStart: true, clearEnd: true),
        expectedVideoPath: originalPath,
      );
      await repository.updateVideoReferenceIfCurrent(
        surgeryRecordId: record.id,
        expectedVideoPath: originalPath,
        videoPath: 'videos/direct/composite-replaced.mp4',
        videoDisplayName: 'composite-replaced.mp4',
      );
    });
    pending.complete(
      const RecordVideoState(RecordVideoStateKind.availableManaged),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('この工程の記録位置を取得できませんでした。'), findsOneWidget);
    expect(find.text('動画が更新されました。もう一度お試しください。'), findsNothing);
  });

  testWidgets('活性化前に症例が削除済みなら新しい画面を開かない', (tester) async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repository = SurgeryRepository(database);
    final service = _DirectJumpVideoService(
      repository,
      videoStateKind: RecordVideoStateKind.availableManaged,
    );
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 1,
      measurements: [
        measurement(
          id: 'deleted-record',
          date: DateTime(2026, 8, 20),
          step: SurgicalStep.capsulorhexis,
          start: 1000,
          end: 3000,
        ),
      ],
    );
    await pumpDatabaseAnalysis(
      tester,
      database: database,
      repository: repository,
      videoService: service,
      snapshot: snapshot,
    );
    await selectCccMetric(tester);

    await tapSelectedCardButton(tester);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnalysisScreen), findsOneWidget);
    expect(find.byType(RecordDetailScreen), findsNothing);
    expect(find.text('症例が見つかりませんでした。'), findsOneWidget);
    expect(service.inspectionCount, 0);
  });
}
