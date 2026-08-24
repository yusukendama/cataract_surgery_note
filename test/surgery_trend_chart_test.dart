import 'dart:ui' show SemanticsAction;

import 'package:cataract_surgery_note/src/features/analysis/date_label_layout.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
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
        expect(
          indices.last,
          pointCount - 1,
          reason: 'pointCount=$pointCount で最新の症例が欠けている',
        );
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
        for (var i = 1; i < indices.length; i++) {
          final gap = (indices[i] - indices[i - 1]) * step;
          expect(
            gap,
            greaterThanOrEqualTo(minimumGap),
            reason: 'pointCount=$pointCount でラベルが重なる (gap=$gap)',
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
      final middle = indices.sublist(1, indices.length - 1);
      expect(middle.any((index) => index > 15 && index < 35), isTrue);
    });

    test('先頭と末尾すら並べられない幅では最新のみを返す', () {
      expect(
        selectDateLabelIndices(pointCount: 20, plotWidth: 30, minimumGap: 40),
        [19],
      );
    });
  });

  group('SurgeryTrendChart', () {
    testWidgets('全高帯は選択だけ、表示マーカーは直接activateする', (tester) async {
      final selected = <String>[];
      final activated = <String>[];
      final points = _points(3);
      await _pumpChart(
        tester,
        points: points,
        selectedRecordId: 'r2',
        onSelected: (point) => selected.add(point.recordId),
        onActivated: (point) => activated.add(point.recordId),
      );

      final middleBand = tester.getRect(
        find.byKey(const Key('analysis-point-r1')),
      );
      await tester.tapAt(Offset(middleBand.center.dx, middleBand.top + 1));
      await tester.pump();

      expect(selected, ['r1']);
      expect(activated, isEmpty);

      selected.clear();
      await tester.tap(find.byKey(const Key('analysis-direct-point-r0')));
      await tester.pump();

      expect(selected, ['r0']);
      expect(activated, ['r0']);
    });

    testWidgets('44×44の半開区間でleft/topだけ境界を含む', (tester) async {
      final activated = <String>[];
      await _pumpChart(
        tester,
        points: _points(1),
        selectedRecordId: 'r0',
        onActivated: (point) => activated.add(point.recordId),
      );

      final target = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r0')),
      );
      final chart = tester.getRect(
        find.byKey(const Key('analysis-trend-adjustable')),
      );
      expect(target.size, const Size(44, 44));
      expect(target.left, greaterThanOrEqualTo(chart.left));
      expect(target.top, greaterThanOrEqualTo(chart.top));
      expect(target.right, lessThanOrEqualTo(chart.right));
      expect(target.bottom, lessThanOrEqualTo(chart.bottom));

      await tester.tapAt(Offset(target.left, target.center.dy));
      await tester.pump();
      await tester.tapAt(Offset(target.center.dx, target.top));
      await tester.pump();
      expect(activated, ['r0', 'r0']);

      await tester.tapAt(Offset(target.right, target.center.dy));
      await tester.pump();
      await tester.tapAt(Offset(target.center.dx, target.bottom));
      await tester.pump();
      expect(activated, ['r0', 'r0']);
    });

    testWidgets('重なりは二乗Euclidean距離、選択点、新しい側の順で解決する', (tester) async {
      final points = _points(10, sameDuration: true);
      final activated = <String>[];
      await _pumpChart(
        tester,
        points: points,
        selectedRecordId: 'r4',
        onActivated: (point) => activated.add(point.recordId),
      );

      var fourth = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r4')),
      );
      var fifth = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r5')),
      );
      var midpoint = Offset(
        (fourth.center.dx + fifth.center.dx) / 2,
        fourth.center.dy,
      );
      await tester.tapAt(midpoint);
      await tester.pump();
      expect(activated, ['r4']);

      activated.clear();
      await _pumpChart(
        tester,
        points: points,
        selectedRecordId: 'r0',
        onActivated: (point) => activated.add(point.recordId),
      );
      fourth = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r4')),
      );
      fifth = tester.getRect(find.byKey(const Key('analysis-direct-point-r5')));
      midpoint = Offset(
        (fourth.center.dx + fifth.center.dx) / 2,
        fourth.center.dy,
      );

      await tester.tapAt(midpoint.translate(-2, 0));
      await tester.pump();
      expect(activated, ['r4']);

      activated.clear();
      await tester.tapAt(midpoint);
      await tester.pump();
      expect(activated, ['r5']);
    });

    testWidgets('高密度は選択マーカーだけ直接領域を持ち2回で開く', (tester) async {
      final selected = <String>[];
      final activated = <String>[];
      final points = _points(50);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: _InteractiveChart(
                  points: points,
                  initialSelectedRecordId: 'r49',
                  onSelected: (point) => selected.add(point.recordId),
                  onActivated: (point) => activated.add(point.recordId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('analysis-direct-point-r49')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('analysis-direct-point-r10')), findsNothing);

      await tester.tap(find.byKey(const Key('analysis-point-r10')));
      await tester.pump();
      expect(selected, ['r10']);
      expect(activated, isEmpty);
      expect(
        find.byKey(const Key('analysis-direct-point-r10')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('analysis-direct-point-r49')), findsNothing);

      await tester.tap(find.byKey(const Key('analysis-direct-point-r10')));
      await tester.pump();
      expect(activated, ['r10']);
    });

    testWidgets('高密度で省略点座標と表示領域が重なる場合は表示点を優先し領域外で省略点を選ぶ', (tester) async {
      final selected = <String>[];
      final activated = <String>[];
      final points = _points(50, sameDuration: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: _InteractiveChart(
                  points: points,
                  initialSelectedRecordId: 'r49',
                  onSelected: (point) => selected.add(point.recordId),
                  onActivated: (point) => activated.add(point.recordId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final visibleTarget = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r49')),
      );
      final hiddenBand = tester.getRect(
        find.byKey(const Key('analysis-point-r48')),
      );
      final overlappingHiddenCoordinate = Offset(
        hiddenBand.center.dx,
        visibleTarget.center.dy,
      );
      expect(visibleTarget.contains(overlappingHiddenCoordinate), isTrue);

      await tester.tapAt(overlappingHiddenCoordinate);
      await tester.pump();
      expect(activated, ['r49']);

      selected.clear();
      await tester.tapAt(
        Offset(hiddenBand.center.dx, visibleTarget.bottom + 1),
      );
      await tester.pump();
      expect(selected, ['r48']);
      expect(activated, ['r49']);
      expect(
        find.byKey(const Key('analysis-direct-point-r48')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('analysis-direct-point-r48')));
      await tester.pump();
      expect(activated, ['r49', 'r48']);
    });

    testWidgets('密度別の直接ジャンプ案内を個別工程だけ表示する', (tester) async {
      await _pumpChart(
        tester,
        points: _points(3),
        selectedRecordId: 'r2',
        onActivated: (_) {},
      );
      expect(find.textContaining('利用できない場合は症例詳細'), findsOneWidget);

      await _pumpChart(
        tester,
        points: _points(50),
        selectedRecordId: 'r49',
        onActivated: (_) {},
      );
      expect(find.textContaining('表示中の点を避けて'), findsOneWidget);

      await _pumpChart(
        tester,
        points: _points(3, step: SurgicalStep.totalSurgeryTime),
        selectedRecordId: 'r2',
      );
      expect(find.byKey(const Key('analysis-chart-direct-hint')), findsNothing);
    });

    testWidgets('Semanticsは1 nodeで増減は選択、tapは選択中をactivateする', (tester) async {
      final semantics = tester.ensureSemantics();
      final selected = <String>[];
      final activated = <String>[];
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
                  onSelected: (point) => selected.add(point.recordId),
                  onActivated: (point) => activated.add(point.recordId),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      const graphKey = Key('analysis-trend-adjustable');
      final graphFinder = find.byKey(graphKey);
      var graph = tester.getSemantics(graphFinder);
      expect(graph.label, 'CCCの推移');
      expect(graph.value, contains('全3件中3件目'));
      expect(graph.value, contains('2026年1月3日'));
      expect(graph.value, contains('CCC'));
      expect(graph.hint, contains('上下スワイプで症例を選択'));
      expect(graph.hint, contains('ダブルタップ'));
      expect(
        graph.getSemanticsData().hasAction(SemanticsAction.increase),
        isTrue,
      );
      expect(
        graph.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );
      expect(graph.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      graph.owner!.performAction(graph.id, SemanticsAction.decrease);
      await tester.pump();
      expect(selected, ['r1']);
      expect(activated, isEmpty);
      expect(tester.getSemantics(graphFinder).value, contains('全3件中2件目'));

      graph = tester.getSemantics(graphFinder);
      graph.owner!.performAction(graph.id, SemanticsAction.tap);
      await tester.pump();
      expect(activated, ['r1']);
      semantics.dispose();
    });

    testWidgets('callbackがないグラフはSemantics tapと動画hintを持たない', (tester) async {
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
      semantics.dispose();
    });

    testWidgets('enabled=falseは全tapとSemantics actionを無効化する', (tester) async {
      final semantics = tester.ensureSemantics();
      final selected = <String>[];
      final activated = <String>[];
      await _pumpChart(
        tester,
        points: _points(3),
        selectedRecordId: 'r2',
        enabled: false,
        onSelected: (point) => selected.add(point.recordId),
        onActivated: (point) => activated.add(point.recordId),
      );

      await tester.tap(find.byKey(const Key('analysis-point-r1')));
      await tester.pump();
      expect(selected, isEmpty);
      expect(activated, isEmpty);
      expect(find.byKey(const Key('analysis-direct-point-r2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('analysis-direct-point-r2')));
      await tester.pump();
      expect(selected, isEmpty);
      expect(activated, isEmpty);

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

    testWidgets('2件の先頭と末尾はplot内へ寄せた44×44領域を維持する', (tester) async {
      await _pumpChart(
        tester,
        points: _points(2),
        selectedRecordId: 'r1',
        onActivated: (_) {},
        width: 320,
      );

      final chart = tester.getRect(
        find.byKey(const Key('analysis-trend-adjustable')),
      );
      final first = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r0')),
      );
      final last = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r1')),
      );

      for (final target in [first, last]) {
        expect(target.size, const Size(44, 44));
        expect(target.left, greaterThan(chart.left));
        expect(target.top, greaterThan(chart.top));
        expect(target.right, lessThan(chart.right));
        expect(target.bottom, lessThan(chart.bottom));
      }
      expect(first.left, lessThan(last.left));
    });

    testWidgets('xとyが異なる重複領域も二次元Euclidean距離で解決する', (tester) async {
      final activated = <String>[];
      await _pumpChart(
        tester,
        points: _points(10),
        selectedRecordId: 'r0',
        onActivated: (point) => activated.add(point.recordId),
      );

      final older = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r4')),
      );
      final newer = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r5')),
      );
      expect(older.center.dx, isNot(newer.center.dx));
      expect(older.center.dy, isNot(newer.center.dy));
      final overlap = older.intersect(newer);
      expect(overlap.isEmpty, isFalse);

      final towardNewer = Offset.lerp(older.center, newer.center, 0.75)!;
      expect(overlap.contains(towardNewer), isTrue);
      await tester.tapAt(towardNewer);
      await tester.pump();

      expect(activated, ['r5']);
    });

    testWidgets('Light/Darkと320幅から動的拡張後も領域と操作を維持する', (tester) async {
      for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
        final activated = <String>[];
        await _pumpChart(
          tester,
          points: _points(2),
          selectedRecordId: 'r1',
          onActivated: (point) => activated.add(point.recordId),
          width: 320,
          textScale: 2,
          themeMode: themeMode,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const Key('analysis-direct-point-r1'))),
          const Size(44, 44),
        );

        await _pumpChart(
          tester,
          points: _points(2),
          selectedRecordId: 'r1',
          onActivated: (point) => activated.add(point.recordId),
          width: 600,
          textScale: 2,
          themeMode: themeMode,
        );
        await tester.tap(find.byKey(const Key('analysis-direct-point-r1')));
        await tester.pump();
        expect(activated, ['r1']);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('320×568の左右16px padding後の288px幅でも44×44領域と操作を維持する', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final selected = <String>[];
      final activated = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SurgeryTrendChart(
                points: _points(2),
                selectedRecordId: 'r0',
                onPointSelected: (point) => selected.add(point.recordId),
                onPointActivated: (point) => activated.add(point.recordId),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final chart = tester.getRect(
        find.byKey(const Key('analysis-trend-adjustable')),
      );
      final target = tester.getRect(
        find.byKey(const Key('analysis-direct-point-r1')),
      );
      expect(chart.width, closeTo(288, 0.01));
      expect(target.size, const Size(44, 44));
      expect(target.left, greaterThanOrEqualTo(chart.left));
      expect(target.top, greaterThanOrEqualTo(chart.top));
      expect(target.right, lessThanOrEqualTo(chart.right));
      expect(target.bottom, lessThanOrEqualTo(chart.bottom));

      await tester.tap(find.byKey(const Key('analysis-direct-point-r1')));
      await tester.pump();

      expect(selected, ['r1']);
      expect(activated, ['r1']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('same widgetを6px密度境界の前後へresizeし描画markerだけをactivateする', (
      tester,
    ) async {
      const pointCount = 50;
      const belowThreshold = 5.9;
      const aboveThreshold = 6.1;
      final width = ValueNotifier<double>(360);
      addTearDown(width.dispose);
      final selected = <String>[];
      final activated = <String>[];
      final points = _points(pointCount);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ValueListenableBuilder<double>(
                valueListenable: width,
                child: _InteractiveChart(
                  points: points,
                  initialSelectedRecordId: 'r49',
                  onSelected: (point) => selected.add(point.recordId),
                  onActivated: (point) => activated.add(point.recordId),
                ),
                builder: (context, chartWidth, chart) =>
                    SizedBox(width: chartWidth, child: chart),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      double measuredSlotWidth() =>
          tester.getSize(find.byKey(const Key('analysis-point-r10'))).width;
      Finder directTargets() => find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('analysis-direct-point-');
      });

      // plotの固定insetを実レイアウトから逆算し、同じwidgetを
      // marker表示境界の直下へ動的にresizeする。
      width.value += (belowThreshold - measuredSlotWidth()) * (pointCount - 1);
      await tester.pump();

      expect(measuredSlotWidth(), closeTo(belowThreshold, 0.01));
      expect(directTargets(), findsOneWidget);
      expect(
        find.byKey(const Key('analysis-direct-point-r49')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('analysis-direct-point-r10')), findsNothing);

      await tester.tap(find.byKey(const Key('analysis-point-r10')));
      await tester.pump();

      expect(selected, ['r10']);
      expect(activated, isEmpty);
      expect(directTargets(), findsOneWidget);
      expect(
        find.byKey(const Key('analysis-direct-point-r10')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('analysis-direct-point-r49')), findsNothing);

      // 同じchart stateと選択を保ったまま境界の直上へ拡張すると、
      // すべての描画markerに直接領域が復帰する。
      width.value += (aboveThreshold - belowThreshold) * (pointCount - 1);
      await tester.pump();

      expect(measuredSlotWidth(), closeTo(aboveThreshold, 0.01));
      expect(directTargets(), findsNWidgets(pointCount));
      expect(
        find.byKey(const Key('analysis-direct-point-r10')),
        findsOneWidget,
      );
      expect(activated, isEmpty);

      await tester.tapAt(
        tester
            .getRect(find.byKey(const Key('analysis-direct-point-r20')))
            .center,
      );
      await tester.pump();

      expect(selected, ['r10', 'r20']);
      expect(activated, ['r20']);

      // 再び狭めても、選択中のmarker r20だけは残り、resize自体で
      // 誤ったactivateが追加されない。
      width.value -= (aboveThreshold - belowThreshold) * (pointCount - 1);
      await tester.pump();

      expect(measuredSlotWidth(), closeTo(belowThreshold, 0.01));
      expect(directTargets(), findsOneWidget);
      expect(
        find.byKey(const Key('analysis-direct-point-r20')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('analysis-direct-point-r10')), findsNothing);
      expect(activated, ['r20']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('INT64境界由来の巨大時間と文字倍率2でも44px領域を維持する', (tester) async {
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
        onActivated: (_) {},
        width: 320,
        textScale: 2,
      );

      expect(
        tester.getSize(find.byKey(const Key('analysis-direct-point-boundary'))),
        const Size(44, 44),
      );
      expect(tester.takeException(), isNull);
    });
  });
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

Future<void> _pumpChart(
  WidgetTester tester, {
  required List<SurgeryTrendPoint> points,
  required String selectedRecordId,
  ValueChanged<SurgeryTrendPoint>? onSelected,
  ValueChanged<SurgeryTrendPoint>? onActivated,
  bool enabled = true,
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
                  onPointSelected: onSelected ?? (_) {},
                  onPointActivated: onActivated,
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
    this.onSelected,
    this.onActivated,
  });

  final List<SurgeryTrendPoint> points;
  final String initialSelectedRecordId;
  final ValueChanged<SurgeryTrendPoint>? onSelected;
  final ValueChanged<SurgeryTrendPoint>? onActivated;

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
      onPointSelected: (point) {
        widget.onSelected?.call(point);
        setState(() => _selectedRecordId = point.recordId);
      },
      onPointActivated: widget.onActivated,
    );
  }
}
