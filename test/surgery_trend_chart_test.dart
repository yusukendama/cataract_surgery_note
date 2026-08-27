import 'dart:ui' show SemanticsAction;

import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/date_label_layout.dart';
import 'package:cataract_surgery_note/src/features/analysis/duration_axis_layout.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selectDateLabelIndices', () {
    test('症例が1件のときは先頭のみを返す', () {
      expect(
        selectDateLabelIndices(pointCount: 1, plotWidth: 240, minimumGap: 40),
        [0],
      );
    });

    test('全ラベルが収まるときは全症例分を返す', () {
      expect(
        selectDateLabelIndices(pointCount: 5, plotWidth: 240, minimumGap: 40),
        [0, 1, 2, 3, 4],
      );
    });

    test('先頭と末尾は常に含まれる', () {
      for (final pointCount in [2, 3, 5, 12, 30, 100, 365]) {
        final indices = selectDateLabelIndices(
          pointCount: pointCount,
          plotWidth: 240,
          minimumGap: 40,
        );
        expect(indices.first, 0, reason: 'pointCount=$pointCount で最初の症例が欠けている');
        expect(indices.last, pointCount - 1);
      }
    });

    test('採用したラベルの中心間距離は常に minimumGap 以上', () {
      const plotWidth = 240.0;
      const minimumGap = 40.0;
      for (final pointCount in [2, 3, 5, 12, 30, 100, 365]) {
        final indices = selectDateLabelIndices(
          pointCount: pointCount,
          plotWidth: plotWidth,
          minimumGap: minimumGap,
        );
        final step = plotWidth / (pointCount - 1);
        for (var index = 1; index < indices.length; index++) {
          expect(
            (indices[index] - indices[index - 1]) * step,
            greaterThanOrEqualTo(minimumGap),
          );
        }
      }
    });

    test('返すインデックスは昇順かつ範囲内', () {
      final indices = selectDateLabelIndices(
        pointCount: 100,
        plotWidth: 240,
        minimumGap: 40,
      );
      expect(indices, orderedEquals(indices.toList()..sort()));
      expect(indices.toSet().length, indices.length);
      expect(indices.every((index) => index >= 0 && index < 100), isTrue);
    });

    test('症例数が多いと中間地点付近のラベルも残る', () {
      final indices = selectDateLabelIndices(
        pointCount: 50,
        plotWidth: 240,
        minimumGap: 40,
      );
      expect(indices.length, greaterThanOrEqualTo(3));
      expect(
        indices
            .sublist(1, indices.length - 1)
            .any((index) => index > 15 && index < 35),
        isTrue,
      );
    });

    test('先頭と末尾すら並べられない幅では最新のみを返す', () {
      expect(
        selectDateLabelIndices(pointCount: 20, plotWidth: 30, minimumGap: 40),
        [19],
      );
    });
  });

  group('DurationAxisLayout', () {
    test('表示可能数はP/(H+4)の直前・一致・直後でfloorして2〜12に収める', () {
      const labelHeight = 16.0;

      expect(
        calculateDurationAxisTickCapacity(
          plotHeight: 39.999,
          labelHeight: labelHeight,
        ),
        2,
      );
      expect(
        calculateDurationAxisTickCapacity(
          plotHeight: 40,
          labelHeight: labelHeight,
        ),
        3,
      );
      expect(
        calculateDurationAxisTickCapacity(
          plotHeight: 40.001,
          labelHeight: labelHeight,
        ),
        3,
      );
      expect(
        calculateDurationAxisTickCapacity(
          plotHeight: 0,
          labelHeight: labelHeight,
        ),
        2,
      );
      expect(
        calculateDurationAxisTickCapacity(
          plotHeight: 10000,
          labelHeight: labelHeight,
        ),
        12,
      );
    });

    test('表示可能数計算は非有限値と不正な高さを拒否する', () {
      expect(
        () => calculateDurationAxisTickCapacity(
          plotHeight: double.infinity,
          labelHeight: 16,
        ),
        throwsArgumentError,
      );
      expect(
        () =>
            calculateDurationAxisTickCapacity(plotHeight: 100, labelHeight: 0),
        throwsArgumentError,
      );
    });

    testWidgets('制御済みgeometryの13分42秒は偶数分の描画commandだけを生成する', (tester) async {
      final layout = _durationLayout(
        maximumDuration: const Duration(minutes: 13, seconds: 42),
        height: 400,
      );

      expect(layout.maximumTickCount, 12);
      expect(layout.scale.interval, const Duration(minutes: 2));
      expect(layout.scale.maximum, const Duration(minutes: 14));
      expect(layout.ticks.map((tick) => tick.label), [
        '0分',
        '2分',
        '4分',
        '6分',
        '8分',
        '10分',
        '12分',
        '14分',
      ]);
      expect(layout.ticks.map((tick) => tick.tick), [
        for (var minute = 0; minute <= 14; minute += 2)
          Duration(minutes: minute),
      ]);
      _expectDurationLabelsFit(layout, canvasHeight: 400);
    });

    testWidgets('狭いplot高さでは目盛りを抜かず軸全体を5分刻みへ切り替える', (tester) async {
      final layout = _durationLayout(
        maximumDuration: const Duration(minutes: 13, seconds: 42),
        height: 150,
      );

      expect(layout.maximumTickCount, lessThan(8));
      expect(layout.scale.interval, const Duration(minutes: 5));
      expect(layout.ticks.map((tick) => tick.label), [
        '0分',
        '5分',
        '10分',
        '15分',
      ]);
      _expectDurationLabelsFit(layout, canvasHeight: 150);
    });

    testWidgets('文字倍率1と2でラベル間に4px以上を確保し上下をclipしない', (tester) async {
      const maximum = Duration(minutes: 13, seconds: 42);
      for (final textScale in [1.0, 2.0]) {
        final scaler = TextScaler.linear(textScale);
        final height = DurationAxisLayout.chartHeightFor(
          textStyle: _axisTextStyle,
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        );
        final layout = _durationLayout(
          maximumDuration: maximum,
          height: height,
          textScaler: scaler,
        );

        expect(
          layout.plotHeight,
          greaterThanOrEqualTo(
            layout.labelHeight + durationAxisMinimumLabelGap,
          ),
        );
        _expectDurationLabelsFit(layout, canvasHeight: height);
      }
    });

    testWidgets('必須viewport幅と文字倍率でplotを反転させず通常ラベルを省略しない', (tester) async {
      const chartWidths = <double>[
        288, // 320 phone / compact Split Viewから左右paddingを除いた幅
        398, // 430 phone
        536, // 568 phone landscape
        736, // 768 iPad portrait
        900, // 932 phone landscape
        992, // 1024 iPad landscape
      ];
      for (final textScale in [1.0, 2.0]) {
        final scaler = TextScaler.linear(textScale);
        final height = DurationAxisLayout.chartHeightFor(
          textStyle: _axisTextStyle,
          textScaler: scaler,
          textDirection: TextDirection.ltr,
        );
        for (final width in chartWidths) {
          final layout = _durationLayout(
            maximumDuration: const Duration(minutes: 13, seconds: 42),
            width: width,
            height: height,
            textScaler: scaler,
          );

          expect(layout.plotWidth, greaterThanOrEqualTo(44));
          expect(layout.ticks, hasLength(layout.scale.ticks.length));
          expect(
            layout.ticks.every((tick) => tick.labelBounds.left >= 0),
            isTrue,
            reason: 'width=$width, textScale=$textScale',
          );
          _expectDurationLabelsFit(layout, canvasHeight: height);
        }
      }
    });

    testWidgets('表現上限値でも全座標を有限にし44pxのplotを維持する', (tester) async {
      final scaler = TextScaler.linear(2);
      final height = DurationAxisLayout.chartHeightFor(
        textStyle: _axisTextStyle,
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      );
      final layout = _durationLayout(
        maximumDuration: const Duration(microseconds: 9223372036854775807),
        width: 288,
        height: height,
        textScaler: scaler,
      );

      expect(layout.scale.isAtRepresentationLimit, isTrue);
      expect(layout.plotWidth, greaterThanOrEqualTo(44));
      expect(layout.plotTop.isFinite, isTrue);
      expect(layout.plotBottom.isFinite, isTrue);
      expect(layout.ticks.every((tick) => tick.y.isFinite), isTrue);
      expect(
        layout.ticks.every(
          (tick) =>
              tick.labelBounds.left.isFinite &&
              tick.labelBounds.top.isFinite &&
              tick.labelBounds.right.isFinite &&
              tick.labelBounds.bottom.isFinite,
        ),
        isTrue,
      );
      _expectDurationLabelsFit(layout, canvasHeight: height);
    });

    testWidgets('文字倍率・高さ・最大値の変更後は軸を決定し直す', (tester) async {
      final regular = _durationLayout(
        maximumDuration: const Duration(minutes: 13, seconds: 42),
        height: 400,
      );
      final constrained = _durationLayout(
        maximumDuration: const Duration(minutes: 13, seconds: 42),
        height: 150,
      );
      final scaled = _durationLayout(
        maximumDuration: const Duration(minutes: 13, seconds: 42),
        height: 400,
        textScaler: TextScaler.linear(2),
      );
      final changedData = _durationLayout(
        maximumDuration: const Duration(minutes: 4, seconds: 12),
        height: 400,
      );

      expect(regular.scale.interval, const Duration(minutes: 2));
      expect(constrained.scale.interval, const Duration(minutes: 5));
      expect(scaled.labelHeight, greaterThan(regular.labelHeight));
      expect(changedData.scale.interval, const Duration(minutes: 1));
      expect(changedData.ticks.map((tick) => tick.label), [
        '0分',
        '1分',
        '2分',
        '3分',
        '4分',
        '5分',
      ]);
    });
  });

  group('SurgeryTrendChart', () {
    testWidgets('核処理13分42秒を文字倍率1/2・Light/Darkで描画し正確な値を読み上げる', (tester) async {
      final semantics = tester.ensureSemantics();
      final points = _pointsWithDurations(const [
        Duration(minutes: 13),
        Duration(minutes: 13, seconds: 42),
      ]);

      for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
        for (final textScale in [1.0, 2.0]) {
          await _pumpChart(
            tester,
            points: points,
            selectedRecordId: 'r1',
            width: 288,
            textScale: textScale,
            themeMode: themeMode,
          );

          expect(
            find.descendant(
              of: find.byType(SurgeryTrendChart),
              matching: find.byType(CustomPaint),
            ),
            findsOneWidget,
          );
          final graph = tester.getSemantics(
            find.byKey(const Key('analysis-trend-adjustable')),
          );
          expect(graph.value, contains('核処理'));
          expect(graph.value, contains('13分42秒'));
          expect(tester.takeException(), isNull);
        }
      }
      semantics.dispose();
    });

    testWidgets('点・線・空白を含む全高帯は症例選択だけを行う', (tester) async {
      final selected = <String>[];
      await _pumpChart(
        tester,
        points: _points(3),
        selectedRecordId: 'r2',
        onSelected: (point) => selected.add(point.recordId),
      );

      final first = tester.getRect(find.byKey(const Key('analysis-point-r0')));
      final middle = tester.getRect(find.byKey(const Key('analysis-point-r1')));
      final last = tester.getRect(find.byKey(const Key('analysis-point-r2')));

      await tester.tapAt(Offset(first.center.dx, first.top + 1));
      await tester.tapAt(middle.center);
      await tester.tapAt(Offset(last.center.dx, last.bottom - 1));
      await tester.pump();

      expect(selected, ['r0', 'r1', 'r2']);
      expect(find.byKey(const Key('analysis-direct-point-r0')), findsNothing);
      expect(find.byKey(const Key('analysis-direct-point-r2')), findsNothing);
    });

    testWidgets('選択済み点の再tap・double tap・long pressでも遷移用targetを生成しない', (
      tester,
    ) async {
      final selected = <String>[];
      await _pumpChart(
        tester,
        points: _points(1),
        selectedRecordId: 'r0',
        onSelected: (point) => selected.add(point.recordId),
      );

      final target = find.byKey(const Key('analysis-point-r0'));
      await tester.tap(target);
      await tester.tap(target);
      await tester.pump();
      await tester.longPress(target);
      await tester.pump();

      expect(selected, ['r0', 'r0']);
      expect(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('analysis-direct-point-');
        }),
        findsNothing,
      );
    });

    testWidgets('高密度でも省略markerの症例帯を1回で選択する', (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: _InteractiveChart(
                  points: _points(50),
                  initialSelectedRecordId: 'r49',
                  onSelected: (point) => selected.add(point.recordId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('analysis-point-r10')));
      await tester.pump();

      expect(selected, ['r10']);
      final chart = tester.widget<SurgeryTrendChart>(
        find.byType(SurgeryTrendChart),
      );
      expect(chart.selectedRecordId, 'r10');
      expect(find.byKey(const Key('analysis-direct-point-r10')), findsNothing);
    });

    testWidgets('同じ高さの高密度点でもx方向の症例帯だけで選択する', (tester) async {
      final selected = <String>[];
      await _pumpChart(
        tester,
        points: _points(50, sameDuration: true),
        selectedRecordId: 'r49',
        onSelected: (point) => selected.add(point.recordId),
      );

      final hiddenBand = tester.getRect(
        find.byKey(const Key('analysis-point-r48')),
      );
      await tester.tapAt(hiddenBand.center);
      await tester.pump();

      expect(selected, ['r48']);
    });

    testWidgets('個別工程だけ選択後ボタンから動画を開く案内を表示する', (tester) async {
      await _pumpChart(
        tester,
        points: _points(3),
        selectedRecordId: 'r2',
        showProcessVideoHint: true,
      );
      expect(find.textContaining('「症例詳細を見る」から選択した工程の動画'), findsOneWidget);
      expect(find.textContaining('表示中の点を避けて'), findsNothing);

      await _pumpChart(
        tester,
        points: _points(50),
        selectedRecordId: 'r49',
        showProcessVideoHint: true,
      );
      expect(find.textContaining('「症例詳細を見る」から選択した工程の動画'), findsOneWidget);

      await _pumpChart(
        tester,
        points: _points(3, step: SurgicalStep.totalSurgeryTime),
        selectedRecordId: 'r2',
      );
      expect(find.byKey(const Key('analysis-chart-direct-hint')), findsNothing);
    });

    testWidgets('Semanticsは1 nodeで増減だけが選択しtap actionを持たない', (tester) async {
      final semantics = tester.ensureSemantics();
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: _InteractiveChart(
                  points: _points(3),
                  initialSelectedRecordId: 'r2',
                  showProcessVideoHint: true,
                  onSelected: (point) => selected.add(point.recordId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final graphFinder = find.byKey(const Key('analysis-trend-adjustable'));
      var graph = tester.getSemantics(graphFinder);
      expect(graph.label, 'CCCの推移');
      expect(graph.value, contains('全3件中3件目'));
      expect(graph.value, contains('2026年1月3日'));
      expect(graph.hint, contains('症例詳細を見るボタン'));
      expect(graph.hint, isNot(contains('ダブルタップ')));
      expect(
        graph.getSemanticsData().hasAction(SemanticsAction.increase),
        isTrue,
      );
      expect(
        graph.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );
      expect(graph.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);

      graph.owner!.performAction(graph.id, SemanticsAction.decrease);
      await tester.pump();
      expect(selected, ['r1']);
      graph = tester.getSemantics(graphFinder);
      expect(graph.value, contains('全3件中2件目'));
      expect(graph.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      semantics.dispose();
    });

    testWidgets('総手術時間のSemantics hintは工程動画を案内しない', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpChart(
        tester,
        points: _points(3, step: SurgicalStep.totalSurgeryTime),
        selectedRecordId: 'r2',
      );

      final graph = tester.getSemantics(
        find.byKey(const Key('analysis-trend-adjustable')),
      );
      expect(graph.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      expect(graph.hint, isNot(contains('動画')));
      expect(graph.hint, isNot(contains('症例詳細を見るボタン')));
      semantics.dispose();
    });

    testWidgets('enabled=falseはpointerとSemanticsの選択actionを無効化する', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final selected = <String>[];
      await _pumpChart(
        tester,
        points: _points(3),
        selectedRecordId: 'r2',
        enabled: false,
        showProcessVideoHint: true,
        onSelected: (point) => selected.add(point.recordId),
      );

      await tester.tap(find.byKey(const Key('analysis-point-r1')));
      await tester.pump();
      expect(selected, isEmpty);

      final graph = tester.getSemantics(
        find.byKey(const Key('analysis-trend-adjustable')),
      );
      for (final action in [
        SemanticsAction.increase,
        SemanticsAction.decrease,
        SemanticsAction.tap,
      ]) {
        expect(graph.getSemanticsData().hasAction(action), isFalse);
      }
      semantics.dispose();
    });

    testWidgets('320×568・文字倍率2・Light/Darkでも選択操作と案内を維持する', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
        final selected = <String>[];
        await _pumpChart(
          tester,
          points: _points(2),
          selectedRecordId: 'r0',
          onSelected: (point) => selected.add(point.recordId),
          enabled: true,
          showProcessVideoHint: true,
          width: 288,
          textScale: 2,
          themeMode: themeMode,
        );

        expect(
          tester
              .getSize(find.byKey(const Key('analysis-trend-adjustable')))
              .width,
          closeTo(288, 0.01),
        );
        await tester.tap(find.byKey(const Key('analysis-point-r1')));
        await tester.pump();
        expect(selected, ['r1']);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('same widgetの動的resize後も選択だけを行い選択状態を維持する', (tester) async {
      final width = ValueNotifier<double>(320);
      addTearDown(width.dispose);
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: width,
                builder: (context, value, _) => SizedBox(
                  width: value,
                  child: _InteractiveChart(
                    points: _points(50),
                    initialSelectedRecordId: 'r49',
                    showProcessVideoHint: true,
                    onSelected: (point) => selected.add(point.recordId),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('analysis-point-r10')));
      await tester.pump();
      width.value = 600;
      await tester.pump();

      final chart = tester.widget<SurgeryTrendChart>(
        find.byType(SurgeryTrendChart),
      );
      expect(selected, ['r10']);
      expect(chart.selectedRecordId, 'r10');
      expect(find.byKey(const Key('analysis-direct-point-r10')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('INT64境界由来の巨大時間と文字倍率2でもoverflowしない', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final points = [
        SurgeryTrendPoint(
          recordId: 'boundary',
          surgeryDate: DateTime(2026, 1, 1),
          createdAt: DateTime(2026, 1, 1),
          eyeSide: EyeSide.right,
          step: SurgicalStep.capsulorhexis,
          duration: const Duration(milliseconds: 9223372036854775),
        ),
      ];

      await _pumpChart(
        tester,
        points: points,
        selectedRecordId: 'boundary',
        showProcessVideoHint: true,
        width: 320,
        textScale: 2,
      );

      expect(find.byKey(const Key('analysis-point-boundary')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

const _axisTextStyle = TextStyle(fontSize: 12);

DurationAxisLayout _durationLayout({
  required Duration maximumDuration,
  required double height,
  double width = 360,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return DurationAxisLayout.calculate(
    width: width,
    height: height,
    step: SurgicalStep.nucleusRemoval,
    maximumDuration: maximumDuration,
    textStyle: _axisTextStyle,
    textScaler: textScaler,
    textDirection: TextDirection.ltr,
  );
}

void _expectDurationLabelsFit(
  DurationAxisLayout layout, {
  required double canvasHeight,
}) {
  expect(layout.ticks, isNotEmpty);
  expect(
    layout.ticks.first.labelBounds.bottom,
    lessThanOrEqualTo(canvasHeight),
  );
  expect(layout.ticks.last.labelBounds.top, greaterThanOrEqualTo(0));
  expect(layout.ticks.length, lessThanOrEqualTo(layout.maximumTickCount));
  for (var index = 1; index < layout.ticks.length; index++) {
    final lowerLabel = layout.ticks[index - 1].labelBounds;
    final upperLabel = layout.ticks[index].labelBounds;
    expect(
      lowerLabel.top - upperLabel.bottom,
      greaterThanOrEqualTo(durationAxisMinimumLabelGap - 0.001),
      reason: '${layout.ticks[index - 1].label} / ${layout.ticks[index].label}',
    );
  }
}

List<SurgeryTrendPoint> _points(
  int count, {
  SurgicalStep step = SurgicalStep.capsulorhexis,
  bool sameDuration = false,
}) {
  return [
    for (var index = 0; index < count; index++)
      SurgeryTrendPoint(
        recordId: 'r$index',
        surgeryDate: DateTime(2026, 1, 1).add(Duration(days: index)),
        createdAt: DateTime(2026, 1, 1).add(Duration(days: index)),
        eyeSide: index.isEven ? EyeSide.right : EyeSide.left,
        step: step,
        duration: Duration(seconds: sameDuration ? 60 : 60 + index),
      ),
  ];
}

List<SurgeryTrendPoint> _pointsWithDurations(List<Duration> durations) {
  return [
    for (var index = 0; index < durations.length; index++)
      SurgeryTrendPoint(
        recordId: 'r$index',
        surgeryDate: DateTime(2026, 1, 1).add(Duration(days: index)),
        createdAt: DateTime(2026, 1, 1).add(Duration(days: index)),
        eyeSide: index.isEven ? EyeSide.right : EyeSide.left,
        step: SurgicalStep.nucleusRemoval,
        duration: durations[index],
      ),
  ];
}

Future<void> _pumpChart(
  WidgetTester tester, {
  required List<SurgeryTrendPoint> points,
  required String selectedRecordId,
  ValueChanged<SurgeryTrendPoint>? onSelected,
  bool enabled = true,
  bool showProcessVideoHint = false,
  double width = 360,
  double textScale = 1,
  ThemeMode themeMode = ThemeMode.system,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: themeMode,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: SizedBox(
                width: width,
                child: SurgeryTrendChart(
                  points: points,
                  selectedRecordId: selectedRecordId,
                  enabled: enabled,
                  showProcessVideoHint: showProcessVideoHint,
                  onPointSelected: onSelected ?? (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _InteractiveChart extends StatefulWidget {
  const _InteractiveChart({
    required this.points,
    required this.initialSelectedRecordId,
    this.showProcessVideoHint = false,
    this.onSelected,
  });

  final List<SurgeryTrendPoint> points;
  final String initialSelectedRecordId;
  final bool showProcessVideoHint;
  final ValueChanged<SurgeryTrendPoint>? onSelected;

  @override
  State<_InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<_InteractiveChart> {
  late String _selectedRecordId = widget.initialSelectedRecordId;

  @override
  Widget build(BuildContext context) {
    return SurgeryTrendChart(
      points: widget.points,
      selectedRecordId: _selectedRecordId,
      showProcessVideoHint: widget.showProcessVideoHint,
      onPointSelected: (point) {
        widget.onSelected?.call(point);
        setState(() => _selectedRecordId = point.recordId);
      },
    );
  }
}
