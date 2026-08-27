import 'dart:async';

import 'package:cataract_surgery_note/src/data/analysis_time_context.dart';
import 'package:cataract_surgery_note/src/data/providers.dart';
import 'package:cataract_surgery_note/src/domain/analysis_horizontal_axis.dart';
import 'package:cataract_surgery_note/src/domain/calendar_day.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/analysis_screen.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
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

  Future<void> switchToChronological(WidgetTester tester) async {
    final selector = find.byKey(const Key('analysis-horizontal-axis-selector'));
    await tester.ensureVisible(selector);
    await tester.pump();
    await tester.tap(find.descendant(of: selector, matching: find.text('時系列')));
    await tester.pump();
  }

  testWidgets('初期値は症例順でmode切替は選択recordIdと集計を維持する', (tester) async {
    final snapshot = _snapshot([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 20),
    ]);
    await pump(tester, snapshot);

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(chart.horizontalAxis!.mode, AnalysisHorizontalAxisMode.caseOrder);
    expect(chart.selectedRecordId, 'r2');
    expect(find.text('1:02'), findsOneWidget);
    final durationsBeforeSwitch = chart.points
        .map((point) => point.duration)
        .toList();

    await switchToChronological(tester);

    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(
      chart.horizontalAxis!.mode,
      AnalysisHorizontalAxisMode.chronological,
    );
    expect(chart.selectedRecordId, 'r2');
    expect(chart.points.map((point) => point.duration), durationsBeforeSwitch);
    final selector = tester.widget<SegmentedButton<AnalysisHorizontalAxisMode>>(
      find.byKey(const Key('analysis-horizontal-axis-selector')),
    );
    expect(selector.selected, {AnalysisHorizontalAxisMode.chronological});
  });

  testWidgets('横軸説明は必須の解釈制限を示し閉じると起点へfocusを戻す', (tester) async {
    await pump(tester, _snapshot([DateTime(2026, 8, 1)]));
    final help = find.byKey(const Key('analysis-horizontal-axis-help'));
    await tester.ensureVisible(help);
    await tester.tap(help);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AlertDialog, '横軸の説明'), findsOneWidget);
    expect(find.textContaining('アプリ内の登録症例を手術日順'), findsOneWidget);
    expect(find.textContaining('同日内の実際の執刀順は表しません'), findsOneWidget);
    expect(find.textContaining('手術日の暦日間隔'), findsOneWidget);
    expect(find.textContaining('生涯の執刀件数ではなく'), findsOneWidget);
    expect(find.textContaining('手術成績は判断できません'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('analysis-horizontal-axis-help-close')),
    );
    await tester.pumpAndSettle();

    final helpButton = tester.widget<TextButton>(help);
    expect(helpButton.focusNode?.hasFocus, isTrue);
  });

  testWidgets('R=0とR>0,M=0では軸controlとadjustable graphを生成しない', (tester) async {
    for (final snapshot in [
      const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
      SurgeryAnalysisSnapshot(
        recordCount: 1,
        catalog: _catalog([DateTime(2026, 8, 1)]),
        measurements: const [],
        referenceDate: DateTime(2026, 8, 27),
        timezoneIdentifier: 'Asia/Tokyo',
      ),
    ]) {
      await pump(tester, snapshot);
      expect(
        find.byKey(const Key('analysis-horizontal-axis-selector')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('analysis-horizontal-axis-help')),
        findsNothing,
      );
      expect(find.byKey(const Key('analysis-trend-adjustable')), findsNothing);
    }
  });

  testWidgets('選択cardとSemanticsはn/Rとk/Mを別々に示す', (tester) async {
    final catalog = _catalog([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 2),
      DateTime(2026, 8, 3),
      DateTime(2026, 8, 4),
    ]);
    final snapshot = SurgeryAnalysisSnapshot(
      recordCount: 4,
      catalog: catalog,
      measurements: [
        _measurement(catalog[1], durationSeconds: 30),
        _measurement(catalog[3], durationSeconds: 40),
      ],
      referenceDate: DateTime(2026, 8, 10),
      timezoneIdentifier: 'Asia/Tokyo',
    );
    final semantics = tester.ensureSemantics();
    await pump(tester, snapshot);

    final graph = tester.getSemantics(
      find.byKey(const Key('analysis-trend-adjustable')),
    );
    expect(graph.value, contains('横軸は症例順'));
    expect(graph.value, contains('登録4症例'));
    expect(graph.value, contains('4番'));
    expect(graph.value, contains('この指標2件中2件目'));
    expect(graph.value, contains('2026年8月4日'));

    final card = find.byKey(const Key('analysis-selected-point'));
    await tester.dragUntilVisible(
      card,
      find.byKey(const Key('analysis-content')),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(find.text('症例順 4 / 4'), findsOneWidget);
    expect(find.text('この指標 2 / 2'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('時系列の同日clusterだけ同じ横位置と前後確認を案内する', (tester) async {
    final snapshot = _snapshot([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 2),
    ]);
    await pump(tester, snapshot);
    expect(find.textContaining('同日の症例は同じ横位置'), findsNothing);

    await switchToChronological(tester);

    expect(find.textContaining('同日の症例は同じ横位置'), findsOneWidget);
    expect(find.textContaining('前後のボタンで各症例を確認'), findsOneWidget);
  });

  testWidgets('320x568・文字倍率2でも両modeと説明controlへ到達できる', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await pump(tester, _snapshot([DateTime(2026, 8, 1)]), textScale: 2);
    final selector = find.byKey(const Key('analysis-horizontal-axis-selector'));
    final help = find.byKey(const Key('analysis-horizontal-axis-help'));
    await tester.ensureVisible(selector);
    await tester.pump();

    expect(tester.getSize(selector).height, greaterThanOrEqualTo(44));
    expect(find.text('症例順'), findsWidgets);
    expect(find.text('時系列'), findsOneWidget);
    await tester.ensureVisible(help);
    expect(tester.getSize(help).height, greaterThanOrEqualTo(44));

    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, '横軸の説明'), findsOneWidget);
    final close = find.byKey(const Key('analysis-horizontal-axis-help-close'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscapeの左右notchとhome indicator内へcontrol・chartを収める', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(844, 390);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const safeInsets = EdgeInsets.fromLTRB(44, 0, 44, 21);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surgeryAnalysisProvider.overrideWith(
            (ref) async => _snapshot([
              DateTime(2026, 8, 1),
              DateTime(2026, 8, 10),
              DateTime(2026, 8, 20),
            ]),
          ),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(844, 390),
              devicePixelRatio: 1,
              padding: safeInsets,
              viewPadding: safeInsets,
            ),
            child: const AnalysisScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final content = tester.getRect(find.byKey(const Key('analysis-content')));
    expect(content.left, 44);
    expect(content.right, 800);
    expect(content.bottom, 369);

    for (final target in [
      find.byKey(const Key('analysis-horizontal-axis-selector')),
      find.byKey(const Key('analysis-horizontal-axis-help')),
    ]) {
      final rect = tester.getRect(target);
      expect(rect.left, greaterThanOrEqualTo(44));
      expect(rect.right, lessThanOrEqualTo(800));
    }
    final chart = find.byKey(const Key('analysis-chart-interaction'));
    await tester.dragUntilVisible(
      chart,
      find.byKey(const Key('analysis-content')),
      const Offset(0, -200),
    );
    await tester.pump();
    final chartRect = tester.getRect(chart);
    expect(chartRect.left, greaterThanOrEqualTo(44));
    expect(chartRect.right, lessThanOrEqualTo(800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgroundでclock監視を解除しresume直後の日付・timezone変更を反映する', (
    tester,
  ) async {
    final source = _MutableTimeSource(
      AnalysisTimeContext(
        now: DateTime(2026, 8, 27, 23, 59),
        timezoneIdentifier: 'Asia/Tokyo',
      ),
    );
    final scheduler = _ScreenFakeScheduler();
    var analysisReadCount = 0;
    final catalog = _catalog([DateTime(2026, 8, 1)]);
    SurgeryAnalysisSnapshot currentSnapshot() => SurgeryAnalysisSnapshot(
      recordCount: 1,
      catalog: catalog,
      measurements: [_measurement(catalog.single, durationSeconds: 60)],
      referenceDate: source.current.now,
      timezoneIdentifier: source.current.timezoneIdentifier,
    );
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await source.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analysisTimeContextSourceProvider.overrideWithValue(source),
          analysisSchedulerProvider.overrideWithValue(scheduler),
          surgeryAnalysisProvider.overrideWith((ref) async {
            analysisReadCount++;
            return currentSnapshot();
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(scheduler.active, hasLength(1));
    expect(analysisReadCount, 1);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('別route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(scheduler.active, isEmpty, reason: '非current routeでは監視を解除する');
    navigator.pop();
    await tester.pumpAndSettle();
    expect(scheduler.active, hasLength(1), reason: 'route復帰時は即時比較して再開する');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(scheduler.active, isEmpty);

    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 28, 0, 1),
      timezoneIdentifier: 'Asia/Tokyo',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    var chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(chart.horizontalAxis!.referenceDate, const CalendarDay(2026, 8, 28));
    expect(analysisReadCount, 1, reason: '同一timezoneの日付変更はDBを再取得しない');
    expect(scheduler.active, hasLength(1));

    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 27, 16, 1),
      timezoneIdentifier: 'America/Los_Angeles',
    );
    source.emitChange();
    await tester.pumpAndSettle();

    chart = tester.widget<SurgeryTrendChart>(find.byType(SurgeryTrendChart));
    expect(chart.horizontalAxis!.referenceDate, const CalendarDay(2026, 8, 27));
    expect(analysisReadCount, 2, reason: 'timezone変更は新しいSnapshotを取得する');
    expect(chart.selectedRecordId, 'r0');
    expect(scheduler.active, hasLength(1));
  });

  testWidgets('timezone再取得中は更新を明示し失敗時は旧graphを現在値として残さない', (tester) async {
    final source = _MutableTimeSource(
      AnalysisTimeContext(
        now: DateTime(2026, 8, 27, 12),
        timezoneIdentifier: 'Asia/Tokyo',
      ),
    );
    final scheduler = _ScreenFakeScheduler();
    final catalog = _catalog([DateTime(2026, 8, 1)]);
    SurgeryAnalysisSnapshot snapshotForCurrentContext() {
      return SurgeryAnalysisSnapshot(
        recordCount: 1,
        catalog: catalog,
        measurements: [_measurement(catalog.single, durationSeconds: 60)],
        referenceDate: source.current.now,
        timezoneIdentifier: source.current.timezoneIdentifier,
      );
    }

    final firstRefresh = Completer<SurgeryAnalysisSnapshot>();
    final failedRefresh = Completer<SurgeryAnalysisSnapshot>();
    var analysisReadCount = 0;
    addTearDown(source.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analysisTimeContextSourceProvider.overrideWithValue(source),
          analysisSchedulerProvider.overrideWithValue(scheduler),
          surgeryAnalysisProvider.overrideWith((ref) {
            analysisReadCount++;
            return switch (analysisReadCount) {
              1 => Future.value(snapshotForCurrentContext()),
              2 => firstRefresh.future,
              _ => failedRefresh.future,
            };
          }),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();

    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 27, 4),
      timezoneIdentifier: 'America/Los_Angeles',
    );
    source.emitChange();
    await tester.pump();
    await tester.pump();

    expect(analysisReadCount, 2);
    expect(
      find.byKey(const Key('analysis-timezone-refresh-indicator')),
      findsOneWidget,
    );
    final oldChart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(
      oldChart.horizontalAxis!.referenceDate,
      const CalendarDay(2026, 8, 27),
    );

    firstRefresh.complete(snapshotForCurrentContext());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('analysis-timezone-refresh-indicator')),
      findsNothing,
    );
    expect(find.byType(SurgeryTrendChart), findsOneWidget);

    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 27, 13),
      timezoneIdentifier: 'Europe/London',
    );
    source.emitChange();
    await tester.pump();
    await tester.pump();
    expect(analysisReadCount, 3);
    expect(
      find.byKey(const Key('analysis-timezone-refresh-indicator')),
      findsOneWidget,
    );

    failedRefresh.completeError(StateError('timezone refresh failed'));
    await tester.pumpAndSettle();
    expect(find.text('分析データを読み込めませんでした'), findsOneWidget);
    expect(find.byType(SurgeryTrendChart), findsNothing);
    expect(
      find.byKey(const Key('analysis-timezone-refresh-indicator')),
      findsNothing,
    );
  });

  testWidgets('timezone再取得でR=0またはM=0になれば対応する見出しへfocusする', (tester) async {
    final semantics = tester.ensureSemantics();
    final accessibilityEvents = <Map<dynamic, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
          message,
        ) async {
          accessibilityEvents.add(message as Map<dynamic, dynamic>);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });
    final catalog = _catalog([DateTime(2026, 8, 1)]);
    final initial = SurgeryAnalysisSnapshot(
      recordCount: 1,
      catalog: catalog,
      measurements: [_measurement(catalog.single, durationSeconds: 60)],
      referenceDate: DateTime(2026, 8, 27),
      timezoneIdentifier: 'Asia/Tokyo',
    );
    final cases = <(SurgeryAnalysisSnapshot, String)>[
      (
        const SurgeryAnalysisSnapshot(recordCount: 0, measurements: []),
        'まだ症例がありません',
      ),
      (
        SurgeryAnalysisSnapshot(
          recordCount: 1,
          catalog: catalog,
          measurements: const [],
        ),
        '「総手術時間」の計測データがありません',
      ),
    ];

    for (final (terminal, title) in cases) {
      final source = _MutableTimeSource(
        AnalysisTimeContext(
          now: DateTime(2026, 8, 27, 12),
          timezoneIdentifier: 'Asia/Tokyo',
        ),
      );
      final scheduler = _ScreenFakeScheduler();
      var analysisReadCount = 0;
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            analysisTimeContextSourceProvider.overrideWithValue(source),
            analysisSchedulerProvider.overrideWithValue(scheduler),
            surgeryAnalysisProvider.overrideWith((ref) async {
              analysisReadCount++;
              if (analysisReadCount == 1) {
                return initial;
              }
              return terminal.withDisplayContext(
                referenceDate: source.current.now,
                timezoneIdentifier: source.current.timezoneIdentifier,
              );
            }),
          ],
          child: const MaterialApp(home: AnalysisScreen()),
        ),
      );
      await tester.pumpAndSettle();
      accessibilityEvents.clear();

      source.current = AnalysisTimeContext(
        now: DateTime(2026, 8, 27, 4),
        timezoneIdentifier: 'America/Los_Angeles',
      );
      source.emitChange();
      await tester.pumpAndSettle();
      await tester.pump();

      expect(analysisReadCount, 2);
      final heading = find
          .ancestor(of: find.text(title), matching: find.byType(Semantics))
          .first;
      final headingNode = tester.getSemantics(heading);
      expect(
        accessibilityEvents
            .where((event) => event['type'] == 'focus')
            .map((event) => event['nodeId']),
        contains(headingNode.id),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await source.dispose();
    }
    semantics.dispose();
  });

  testWidgets('clock監視開始の一時read失敗後も60秒fallbackから日付を反映する', (tester) async {
    final source = _MutableTimeSource(
      AnalysisTimeContext(
        now: DateTime(2026, 8, 27, 23, 59),
        timezoneIdentifier: 'Asia/Tokyo',
      ),
    )..failNextRead(StateError('temporary clock failure'));
    final scheduler = _ScreenFakeScheduler();
    final snapshot = _snapshot([DateTime(2026, 8, 1)]);
    addTearDown(source.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analysisTimeContextSourceProvider.overrideWithValue(source),
          analysisSchedulerProvider.overrideWithValue(scheduler),
          surgeryAnalysisProvider.overrideWith((ref) async => snapshot),
        ],
        child: const MaterialApp(home: AnalysisScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(scheduler.active, hasLength(1));
    expect(
      scheduler.active.single.delay,
      lessThanOrEqualTo(const Duration(seconds: 60)),
    );
    source.current = AnalysisTimeContext(
      now: DateTime(2026, 8, 28, 0, 1),
      timezoneIdentifier: 'Asia/Tokyo',
    );
    scheduler.active.single.fire();
    await tester.pumpAndSettle();

    final chart = tester.widget<SurgeryTrendChart>(
      find.byType(SurgeryTrendChart),
    );
    expect(chart.horizontalAxis!.referenceDate, const CalendarDay(2026, 8, 28));
    expect(scheduler.active, hasLength(1));
  });
}

SurgeryAnalysisSnapshot _snapshot(List<DateTime> dates) {
  final catalog = _catalog(dates);
  return SurgeryAnalysisSnapshot(
    recordCount: catalog.length,
    catalog: catalog,
    measurements: [
      for (var index = 0; index < catalog.length; index++)
        _measurement(catalog[index], durationSeconds: 60 + index),
    ],
    referenceDate: DateTime(2026, 8, 27),
    timezoneIdentifier: 'Asia/Tokyo',
  );
}

List<SurgeryAnalysisRecord> _catalog(List<DateTime> dates) {
  return [
    for (var index = 0; index < dates.length; index++)
      SurgeryAnalysisRecord(
        recordId: 'r$index',
        surgeryDate: dates[index],
        createdAt: dates[index].add(Duration(minutes: index)),
        rawEyeSide: index.isEven ? EyeSide.right.name : EyeSide.left.name,
        eyeSide: index.isEven ? EyeSide.right : EyeSide.left,
        caseOrdinal: index + 1,
      ),
  ];
}

SurgeryAnalysisMeasurement _measurement(
  SurgeryAnalysisRecord record, {
  required int durationSeconds,
}) {
  return SurgeryAnalysisMeasurement(
    recordId: record.recordId,
    surgeryDate: record.surgeryDate,
    createdAt: record.createdAt,
    eyeSide: record.eyeSide,
    step: SurgicalStep.totalSurgeryTime,
    startMilliseconds: 0,
    endMilliseconds: durationSeconds * 1000,
  );
}

final class _MutableTimeSource implements AnalysisTimeContextSource {
  _MutableTimeSource(this.current);

  AnalysisTimeContext current;
  Object? _nextError;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<AnalysisTimeContext> read() async {
    final error = _nextError;
    _nextError = null;
    if (error != null) {
      throw error;
    }
    return current;
  }

  void failNextRead(Object error) => _nextError = error;

  void emitChange() => _changes.add(null);

  Future<void> dispose() => _changes.close();
}

final class _ScreenFakeScheduler implements AnalysisScheduler {
  final List<_ScreenFakeTask> tasks = [];

  Iterable<_ScreenFakeTask> get active =>
      tasks.where((task) => !task.cancelled);

  @override
  AnalysisScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _ScreenFakeTask(delay, callback);
    tasks.add(task);
    return task;
  }
}

final class _ScreenFakeTask implements AnalysisScheduledTask {
  _ScreenFakeTask(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  void fire() {
    if (cancelled) {
      return;
    }
    cancelled = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}
