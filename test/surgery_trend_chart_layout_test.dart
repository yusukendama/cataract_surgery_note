import 'dart:ui';

import 'package:cataract_surgery_note/src/domain/analysis_horizontal_axis.dart';
import 'package:cataract_surgery_note/src/domain/calendar_day.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart.dart';
import 'package:cataract_surgery_note/src/features/analysis/surgery_trend_chart_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Size measure(String value) => Size(value.length * 8, 14);

  group('DurationAxisLayout integration', () {
    test('両横軸modeで13分42秒を2分刻み・上限14分にする', () {
      final catalog = _catalog(2);
      final points = [
        _point(
          catalog[0],
          const Duration(minutes: 13),
          step: SurgicalStep.nucleusRemoval,
        ),
        _point(
          catalog[1],
          const Duration(minutes: 13, seconds: 42),
          step: SurgicalStep.nucleusRemoval,
        ),
      ];

      for (final mode in AnalysisHorizontalAxisMode.values) {
        final layout = SurgeryTrendChartLayout.calculate(
          width: 360,
          height: 320,
          points: points,
          horizontalAxis: _axis(mode, catalog, const CalendarDay(2028, 1, 1)),
          measureText: measure,
        );

        expect(layout.durationAxis.interval, const Duration(minutes: 2));
        expect(layout.durationAxis.maximum, const Duration(minutes: 14));
        expect(layout.durationAxisLayout.ticks.map((tick) => tick.label), [
          '0分',
          '2分',
          '4分',
          '6分',
          '8分',
          '10分',
          '12分',
          '14分',
        ]);
        expect(layout.points.last.offset.dy, greaterThan(layout.plotTop));
      }
    });

    test('高さ150pxでは規則性を保ったまま5分刻みへ切り替える', () {
      final catalog = _catalog(2);
      final points = [
        _point(
          catalog[0],
          const Duration(minutes: 13),
          step: SurgicalStep.nucleusRemoval,
        ),
        _point(
          catalog[1],
          const Duration(minutes: 13, seconds: 42),
          step: SurgicalStep.nucleusRemoval,
        ),
      ];

      for (final mode in AnalysisHorizontalAxisMode.values) {
        final layout = SurgeryTrendChartLayout.calculate(
          width: 288,
          height: 150,
          points: points,
          horizontalAxis: _axis(mode, catalog, const CalendarDay(2028, 1, 1)),
          measureText: measure,
        );

        expect(layout.durationAxis.interval, const Duration(minutes: 5));
        expect(layout.durationAxis.ticks, const [
          Duration.zero,
          Duration(minutes: 5),
          Duration(minutes: 10),
          Duration(minutes: 15),
        ]);
        expect(layout.plotRectangle.isFinite, isTrue);
        expect(
          layout.durationAxisLayout.ticks.every(
            (tick) =>
                tick.y.isFinite &&
                tick.labelBounds.left.isFinite &&
                tick.labelBounds.right <= layout.plotLeft,
          ),
          isTrue,
        );
      }
    });

    test('表現上限・文字倍率2相当でも両軸geometryを有限に保つ', () {
      final catalog = _catalog(2);
      final maximum = const Duration(microseconds: 9223372036854775807);
      final points = [
        _point(
          catalog[0],
          maximum - const Duration(microseconds: 1),
          step: SurgicalStep.nucleusRemoval,
        ),
        _point(catalog[1], maximum, step: SurgicalStep.nucleusRemoval),
      ];

      for (final mode in AnalysisHorizontalAxisMode.values) {
        final layout = SurgeryTrendChartLayout.calculate(
          width: 288,
          height: 376,
          points: points,
          horizontalAxis: _axis(mode, catalog, const CalendarDay(2028, 1, 1)),
          measureText: (value) => Size(value.length * 16, 28),
        );

        expect(layout.durationAxis.isAtRepresentationLimit, isTrue);
        expect(layout.plotWidth, greaterThanOrEqualTo(44));
        expect(
          layout.points.every(
            (point) => point.offset.dx.isFinite && point.offset.dy.isFinite,
          ),
          isTrue,
        );
        expect(
          layout.horizontalTicks.every(
            (tick) => tick.x.isFinite && tick.labelBounds.isFinite,
          ),
          isTrue,
        );
      }
    });

    test('アクセシビリティ文字で縦軸と横軸のラベルが交差せず画面内に収まる', () {
      final catalog = _catalogForDates([
        DateTime(2026, 1, 1),
        DateTime(2028, 1, 1),
      ]);
      final points = [
        _point(
          catalog[0],
          const Duration(minutes: 13),
          step: SurgicalStep.nucleusRemoval,
        ),
        _point(
          catalog[1],
          const Duration(minutes: 13, seconds: 42),
          step: SurgicalStep.nucleusRemoval,
        ),
      ];

      for (final labelHeight in [28.0, 40.0]) {
        final layout = SurgeryTrendChartLayout.calculate(
          width: 288,
          height: 376,
          points: points,
          horizontalAxis: _axis(
            AnalysisHorizontalAxisMode.chronological,
            catalog,
            const CalendarDay(2028, 1, 1),
          ),
          measureText: (value) => Size(value.length * 16, labelHeight),
        );

        expect(layout.horizontalTicks, isNotEmpty);
        for (final horizontal in layout.horizontalTicks) {
          expect(
            horizontal.labelBounds.bottom,
            lessThanOrEqualTo(layout.height),
          );
          for (final vertical in layout.durationAxisLayout.ticks) {
            expect(
              horizontal.labelBounds.overlaps(vertical.labelBounds),
              isFalse,
              reason:
                  '横軸${horizontal.value.label}と縦軸${vertical.label}が'
                  '文字高$labelHeightで交差しました',
            );
          }
        }
      }
    });
  });

  group('SurgeryTrendChartLayout caseOrder', () {
    test('欠損症例を詰めずR=100のn=98,100へ配置する', () {
      final catalog = _catalog(100);
      final points = [
        _point(catalog[97], const Duration(seconds: 40)),
        _point(catalog[99], const Duration(seconds: 50)),
      ];
      final layout = SurgeryTrendChartLayout.calculate(
        width: 360,
        height: 320,
        points: points,
        horizontalAxis: _axis(
          AnalysisHorizontalAxisMode.caseOrder,
          catalog,
          const CalendarDay(2028, 1, 1),
        ),
        measureText: measure,
      );

      expect(
        (layout.points.first.offset.dx - layout.plotLeft) / layout.plotWidth,
        closeTo(97 / 99, 1e-9),
      );
      expect(layout.points.last.offset.dx, layout.plotRight);
      expect(layout.points.map((point) => point.caseOrdinal), [98, 100]);
    });

    test('x等距離は現在選択を維持し、それ以外はnが大きい点を選ぶ', () {
      final catalog = _catalog(2);
      final layout = _layout(
        mode: AnalysisHorizontalAxisMode.caseOrder,
        catalog: catalog,
        points: [
          _point(catalog[0], const Duration(seconds: 10)),
          _point(catalog[1], const Duration(seconds: 20)),
        ],
      );
      final midpoint =
          (layout.points[0].offset.dx + layout.points[1].offset.dx) / 2;

      expect(
        layout
            .selectPoint(
              localPosition: Offset(midpoint, layout.plotTop),
              selectedRecordId: catalog[0].recordId,
            )
            ?.recordId,
        catalog[0].recordId,
      );
      expect(
        layout
            .selectPoint(
              localPosition: Offset(midpoint, layout.plotTop),
              selectedRecordId: null,
            )
            ?.recordId,
        catalog[1].recordId,
      );
    });
  });

  group('SurgeryTrendChartLayout chronological', () {
    test('同日clusterへjitterを加えずy最寄りを選ぶ', () {
      final catalog = _catalogForDates([
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 10),
      ]);
      final layout = _layout(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: catalog,
        reference: const CalendarDay(2026, 8, 5),
        points: [
          _point(catalog[0], const Duration(seconds: 10)),
          _point(catalog[1], const Duration(seconds: 50)),
          _point(catalog[2], const Duration(seconds: 30)),
        ],
      );

      expect(layout.points[0].offset.dx, layout.points[1].offset.dx);
      expect(
        layout
            .selectPoint(
              localPosition: layout.points[0].offset.translate(0, 1),
              selectedRecordId: null,
            )
            ?.recordId,
        catalog[0].recordId,
      );
      expect(
        layout
            .selectPoint(
              localPosition: layout.points[1].offset.translate(0, -1),
              selectedRecordId: null,
            )
            ?.recordId,
        catalog[1].recordId,
      );
    });

    test('完全重複は現在選択を維持し、未選択なら最大nを選ぶ', () {
      final catalog = _catalogForDates([
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 1),
      ]);
      final points = [
        _point(catalog[0], const Duration(seconds: 20)),
        _point(catalog[1], const Duration(seconds: 20)),
      ];
      final layout = _layout(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: catalog,
        reference: const CalendarDay(2026, 8, 1),
        points: points,
      );

      expect(layout.points[0].offset, layout.points[1].offset);
      expect(layout.points.map((point) => point.markerVisible), [false, false]);
      expect(
        layout
            .selectPoint(
              localPosition: layout.points.first.offset,
              selectedRecordId: catalog[0].recordId,
            )
            ?.recordId,
        catalog[0].recordId,
      );
      expect(
        layout
            .selectPoint(
              localPosition: layout.points.first.offset,
              selectedRecordId: null,
            )
            ?.recordId,
        catalog[1].recordId,
      );
    });

    test('別日clusterのx距離が同値なら新しい手術日を選ぶ', () {
      final catalog = _catalogForDates([
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 3),
      ]);
      final layout = _layout(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: catalog,
        reference: const CalendarDay(2026, 8, 2),
        points: [
          _point(catalog[0], const Duration(seconds: 20)),
          _point(catalog[1], const Duration(seconds: 20)),
        ],
      );
      final midpoint =
          (layout.points[0].offset.dx + layout.points[1].offset.dx) / 2;

      expect(
        layout
            .selectPoint(
              localPosition: Offset(midpoint, layout.points.first.offset.dy),
              selectedRecordId: catalog[0].recordId,
            )
            ?.recordId,
        catalog[1].recordId,
      );
    });
  });

  test('interaction rectangle外を無視し、axis gutter内をplotへclampする', () {
    final catalog = _catalog(3);
    final layout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: catalog,
      points: [
        for (final record in catalog)
          _point(record, Duration(seconds: 10 + record.caseOrdinal)),
      ],
    );

    expect(
      layout.selectPoint(
        localPosition: const Offset(-0.1, 20),
        selectedRecordId: null,
      ),
      isNull,
    );
    expect(
      layout
          .selectPoint(
            localPosition: Offset(1, layout.height - 1),
            selectedRecordId: null,
          )
          ?.recordId,
      catalog.first.recordId,
    );
  });

  test('screen-space距離6px未満だけを省略し同じxで離れたyは残す', () {
    final catalog = _catalogForDates([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 1),
    ]);
    final layout = _layout(
      mode: AnalysisHorizontalAxisMode.chronological,
      catalog: catalog,
      reference: const CalendarDay(2026, 8, 1),
      points: [
        _point(catalog[0], const Duration(seconds: 10)),
        _point(catalog[1], const Duration(seconds: 10)),
        _point(catalog[2], const Duration(seconds: 50)),
      ],
    );

    expect(layout.points[0].markerVisible, isFalse);
    expect(layout.points[1].markerVisible, isFalse);
    expect(layout.points[2].markerVisible, isTrue);
    expect(
      (layout.points[2].offset - layout.points[0].offset).distance,
      greaterThanOrEqualTo(minimumVisibleMarkerDistance),
    );
  });

  test('R=365・全11指標が同じcatalog domainと症例位置を共有する', () {
    final catalog = _catalogForDates([
      for (var index = 0; index < 365; index++)
        DateTime(2025, 1, 1).add(Duration(days: index ~/ 3)),
    ]);
    final measurements = <SurgeryAnalysisMeasurement>[
      for (final record in catalog)
        for (final step in surgicalStepsInDisplayOrder)
          SurgeryAnalysisMeasurement(
            recordId: record.recordId,
            surgeryDate: record.surgeryDate,
            createdAt: record.createdAt,
            eyeSide: record.eyeSide,
            step: step,
            startMilliseconds: 0,
            endMilliseconds: 1000 + record.caseOrdinal + step.index,
          ),
    ];
    const calculator = SurgeryTrendCalculator();
    final caseAxis = _axis(
      AnalysisHorizontalAxisMode.caseOrder,
      catalog,
      const CalendarDay(2026, 1, 1),
    );
    final timeAxis = _axis(
      AnalysisHorizontalAxisMode.chronological,
      catalog,
      const CalendarDay(2026, 1, 1),
    );

    for (final step in surgicalStepsInDisplayOrder) {
      final trend = calculator.calculate(
        measurements,
        step,
        catalog: catalog,
        registeredRecordCount: 365,
      );
      expect(trend.points, hasLength(365));
      final target = trend.points[199];
      expect(target.caseOrdinal, 200);
      expect(
        caseAxis.xRatioForRecordId(target.recordId),
        closeTo(199 / 364, 1e-12),
      );
      for (final axis in [caseAxis, timeAxis]) {
        final layout = SurgeryTrendChartLayout.calculate(
          width: 320,
          height: 360,
          points: trend.points,
          horizontalAxis: axis,
          measureText: (value) => Size(value.length * 8, 14),
        );
        final targetLayout = layout.points[199];
        expect(
          (targetLayout.offset.dx - layout.plotLeft) / layout.plotWidth,
          closeTo(axis.xRatioForRecordId(target.recordId), 1e-12),
        );
      }
    }

    final sparse = calculator.calculate(
      measurements.where(
        (measurement) =>
            measurement.step == SurgicalStep.capsulorhexis &&
            catalog
                        .firstWhere(
                          (record) => record.recordId == measurement.recordId,
                        )
                        .caseOrdinal %
                    50 ==
                0,
      ),
      SurgicalStep.capsulorhexis,
      catalog: catalog,
      registeredRecordCount: 365,
    );
    expect(sparse.points.map((point) => point.caseOrdinal), [
      50,
      100,
      150,
      200,
      250,
      300,
      350,
    ]);
    expect(
      caseAxis.xRatioForRecordId(sparse.points.last.recordId),
      closeTo(349 / 364, 1e-12),
    );
  });

  test('R=1000でもtickは32以下で全点と有限geometryを維持する', () {
    final catalog = _catalog(1000);
    final points = [
      for (final record in catalog)
        _point(record, Duration(milliseconds: 1000 + record.caseOrdinal)),
    ];
    for (final mode in AnalysisHorizontalAxisMode.values) {
      final layout = SurgeryTrendChartLayout.calculate(
        width: 320,
        height: 360,
        points: points,
        horizontalAxis: _axis(mode, catalog, const CalendarDay(2030, 1, 1)),
        measureText: (value) => Size(value.length * 16, 28),
      );

      expect(layout.points, hasLength(1000));
      expect(layout.horizontalTicks.length, lessThanOrEqualTo(32));
      expect(
        layout.points.every(
          (point) => point.offset.dx.isFinite && point.offset.dy.isFinite,
        ),
        isTrue,
      );
      for (var index = 1; index < layout.horizontalTicks.length; index++) {
        expect(
          layout.horizontalTicks[index].labelBounds.left -
              layout.horizontalTicks[index - 1].labelBounds.right,
          greaterThanOrEqualTo(8),
        );
      }
    }
  });

  test('drawing commandは両modeの線・marker・tick・label実座標をpainterへ渡す', () {
    final catalog = _catalog(3);
    final points = [
      for (final record in catalog)
        _point(record, Duration(seconds: record.caseOrdinal * 10)),
    ];
    for (final mode in AnalysisHorizontalAxisMode.values) {
      final layout = _layout(mode: mode, catalog: catalog, points: points);
      final commands = trendChartPaintCommands(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
      );
      expect(
        commands.line!.vertices.map((vertex) => vertex.recordId),
        points.map((point) => point.recordId),
      );
      expect(
        commands.line!.vertices.map((vertex) => vertex.offset),
        layout.points.map((point) => point.offset),
      );
      expect(commands.markers, hasLength(3));
      final selected = commands.markers.singleWhere(
        (marker) => marker.kind == TrendChartMarkerPaintKind.selected,
      );
      expect(selected.recordId, catalog[1].recordId);
      expect(selected.center, layout.points[1].offset);
      expect(selected.radius, 7);
      expect(selected.ringWidth, 3);
      final unselected = commands.markers.where(
        (marker) => marker.kind == TrendChartMarkerPaintKind.unselected,
      );
      expect(unselected.map((marker) => marker.recordId), ['r0', 'r2']);
      expect(unselected.every((marker) => marker.radius == 3.5), isTrue);
      expect(
        commands.horizontalTickMarks,
        hasLength(layout.horizontalTicks.length),
      );
      expect(
        commands.horizontalLabels,
        hasLength(layout.horizontalTicks.length),
      );
      for (var index = 0; index < layout.horizontalTicks.length; index++) {
        expect(
          commands.horizontalTickMarks[index].start,
          Offset(layout.horizontalTicks[index].x, layout.plotBottom),
        );
        expect(
          commands.horizontalTickMarks[index].end,
          Offset(layout.horizontalTicks[index].x, layout.plotBottom + 5),
        );
        expect(
          commands.horizontalLabels[index].text,
          layout.horizontalTicks[index].value.label,
        );
        expect(
          commands.horizontalLabels[index].origin,
          layout.horizontalTicks[index].labelBounds.topLeft,
        );
      }

      final painter = TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      );
      final recorder = PictureRecorder();

      painter.paint(Canvas(recorder), Size(layout.width, layout.height));
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);
    }
  });

  test('欠測を跨ぐ線と将来日の実座標・labelをcommandに残す', () {
    final missingCatalog = _catalogForDates([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 5),
      DateTime(2026, 8, 10),
    ]);
    final missingPoints = [
      _point(missingCatalog[0], const Duration(seconds: 20)),
      _point(missingCatalog[2], const Duration(seconds: 40)),
    ];
    final missingLayout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: missingCatalog,
      points: missingPoints,
    );
    final missingCommands = trendChartPaintCommands(
      layout: missingLayout,
      selectedRecordId: missingCatalog[2].recordId,
    );

    expect(missingCommands.line!.vertices.map((vertex) => vertex.recordId), [
      'r0',
      'r2',
    ]);
    expect(
      missingCommands.line!.vertices.map((vertex) => vertex.offset),
      missingLayout.points.map((point) => point.offset),
    );
    expect(
      missingCommands.line!.vertices.first.offset.dx,
      missingLayout.plotLeft,
    );
    expect(
      missingCommands.line!.vertices.last.offset.dx,
      missingLayout.plotRight,
    );

    final futureCatalog = _catalogForDates([
      DateTime(2026, 8, 27),
      DateTime(2026, 8, 28),
    ]);
    final futureLayout = _layout(
      mode: AnalysisHorizontalAxisMode.chronological,
      catalog: futureCatalog,
      points: [
        _point(futureCatalog[0], const Duration(seconds: 20)),
        _point(futureCatalog[1], const Duration(seconds: 30)),
      ],
      reference: const CalendarDay(2026, 8, 27),
    );
    final futureCommands = trendChartPaintCommands(
      layout: futureLayout,
      selectedRecordId: futureCatalog[1].recordId,
    );

    expect(
      futureCommands.line!.vertices.last.offset.dx,
      futureLayout.plotRight,
    );
    expect(
      futureCommands.horizontalLabels.map((label) => label.text),
      containsAll(['現在', '1日後']),
    );
  });

  test('同日縦線・完全重複・高密度で線を保ち選択markerを必ず描く', () {
    final sameDayCatalog = _catalogForDates([
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 1),
    ]);
    final sameDayLayout = _layout(
      mode: AnalysisHorizontalAxisMode.chronological,
      catalog: sameDayCatalog,
      points: [
        _point(sameDayCatalog[0], const Duration(seconds: 10)),
        _point(sameDayCatalog[1], const Duration(seconds: 30)),
        _point(sameDayCatalog[2], const Duration(seconds: 30)),
      ],
      reference: const CalendarDay(2026, 8, 1),
    );
    final sameDayCommands = trendChartPaintCommands(
      layout: sameDayLayout,
      selectedRecordId: sameDayCatalog[2].recordId,
    );
    final vertices = sameDayCommands.line!.vertices;

    expect(vertices[0].offset.dx, vertices[1].offset.dx);
    expect(vertices[0].offset.dy, isNot(vertices[1].offset.dy));
    expect(vertices[1].offset, vertices[2].offset);
    expect(sameDayCommands.markers.map((marker) => marker.recordId), [
      'r0',
      'r2',
    ]);
    expect(
      sameDayCommands.markers.last.kind,
      TrendChartMarkerPaintKind.selected,
    );

    final denseCatalog = _catalog(50);
    final denseLayout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: denseCatalog,
      points: [
        for (final record in denseCatalog)
          _point(record, const Duration(seconds: 20)),
      ],
    );
    expect(denseLayout.points[10].markerVisible, isFalse);
    final denseCommands = trendChartPaintCommands(
      layout: denseLayout,
      selectedRecordId: denseCatalog[10].recordId,
    );

    expect(denseCommands.line!.vertices, hasLength(50));
    expect(denseCommands.markers.length, lessThan(50));
    expect(
      denseCommands.markers
          .singleWhere((marker) => marker.recordId == denseCatalog[10].recordId)
          .kind,
      TrendChartMarkerPaintKind.selected,
    );
  });

  test('1点と異なるplot rectangleをそれぞれのcommandに反映する', () {
    final catalog = _catalog(1);
    final point = _point(catalog.single, const Duration(seconds: 20));
    for (final mode in AnalysisHorizontalAxisMode.values) {
      final layout = _layout(mode: mode, catalog: catalog, points: [point]);
      final commands = trendChartPaintCommands(
        layout: layout,
        selectedRecordId: point.recordId,
      );
      expect(commands.line, isNull);
      expect(commands.markers, hasLength(1));
      expect(commands.markers.single.center, layout.points.single.offset);
      expect(commands.markers.single.kind, TrendChartMarkerPaintKind.selected);
      expect(commands.horizontalTickMarks, isNotEmpty);
      expect(commands.horizontalLabels, isNotEmpty);
    }

    final threeCatalog = _catalog(3);
    final points = [
      for (final record in threeCatalog)
        _point(record, Duration(seconds: record.caseOrdinal * 10)),
    ];
    final compact = SurgeryTrendChartLayout.calculate(
      width: 280,
      height: 300,
      points: points,
      horizontalAxis: _axis(
        AnalysisHorizontalAxisMode.caseOrder,
        threeCatalog,
        const CalendarDay(2028, 1, 1),
      ),
      measureText: (value) => Size(value.length * 8, 14),
    );
    final expanded = SurgeryTrendChartLayout.calculate(
      width: 520,
      height: 420,
      points: points,
      horizontalAxis: _axis(
        AnalysisHorizontalAxisMode.caseOrder,
        threeCatalog,
        const CalendarDay(2028, 1, 1),
      ),
      measureText: (value) => Size(value.length * 12, 20),
    );
    final compactCommands = trendChartPaintCommands(
      layout: compact,
      selectedRecordId: 'r1',
    );
    final expandedCommands = trendChartPaintCommands(
      layout: expanded,
      selectedRecordId: 'r1',
    );

    expect(compact.plotRectangle, isNot(expanded.plotRectangle));
    expect(
      compactCommands.line!.vertices.last.offset,
      compact.points.last.offset,
    );
    expect(
      expandedCommands.line!.vertices.last.offset,
      expanded.points.last.offset,
    );
    expect(
      compactCommands.line!.vertices.last.offset,
      isNot(expandedCommands.line!.vertices.last.offset),
    );
    expect(
      compactCommands.horizontalLabels.first.origin,
      compact.horizontalTicks.first.labelBounds.topLeft,
    );
    expect(
      expandedCommands.horizontalLabels.first.origin,
      expanded.horizontalTicks.first.labelBounds.topLeft,
    );
  });

  test('shouldRepaintは同値だけを抑制し必要な全入力差を検知する', () {
    final catalog = _catalog(3);
    final points = [
      for (final record in catalog)
        _point(record, Duration(seconds: record.caseOrdinal * 10)),
    ];

    final layout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: catalog,
      points: points,
    );
    final painter = TrendChartPainter(
      layout: layout,
      selectedRecordId: catalog[1].recordId,
      colorScheme: const ColorScheme.light(),
      textStyle: const TextStyle(fontSize: 12),
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );
    expect(
      painter.shouldRepaint(
        TrendChartPainter(
          layout: layout,
          selectedRecordId: catalog[1].recordId,
          colorScheme: const ColorScheme.light(),
          textStyle: const TextStyle(fontSize: 12),
          textScaler: TextScaler.noScaling,
          textDirection: TextDirection.ltr,
        ),
      ),
      isFalse,
    );
    final equivalentPoints = [
      for (final point in points)
        SurgeryTrendPoint(
          recordId: point.recordId,
          surgeryDate: point.surgeryDate,
          createdAt: point.createdAt,
          eyeSide: point.eyeSide,
          step: point.step,
          duration: point.duration,
          caseOrdinal: point.caseOrdinal,
          registeredRecordCount: point.registeredRecordCount,
        ),
    ];
    final equivalentLayout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: catalog,
      points: equivalentPoints,
    );
    expect(
      TrendChartPainter(
        layout: equivalentLayout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ).shouldRepaint(painter),
      isFalse,
      reason: '同値の再計算結果だけでは不要な再paintを増やさない',
    );
    expect(
      TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[2].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ).shouldRepaint(painter),
      isTrue,
    );

    final changedInputs = <TrendChartPainter>[
      TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.dark(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ),
      TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 13),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ),
      TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: const TextScaler.linear(2),
        textDirection: TextDirection.ltr,
      ),
      TrendChartPainter(
        layout: layout,
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.rtl,
      ),
      TrendChartPainter(
        layout: SurgeryTrendChartLayout.calculate(
          width: 420,
          height: 340,
          points: points,
          horizontalAxis: _axis(
            AnalysisHorizontalAxisMode.caseOrder,
            catalog,
            const CalendarDay(2028, 1, 1),
          ),
          measureText: (value) => Size(value.length * 8, 14),
        ),
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ),
      TrendChartPainter(
        layout: _layout(
          mode: AnalysisHorizontalAxisMode.chronological,
          catalog: catalog,
          points: points,
        ),
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ),
      TrendChartPainter(
        layout: _layout(
          mode: AnalysisHorizontalAxisMode.caseOrder,
          catalog: catalog,
          points: points,
          reference: const CalendarDay(2029, 1, 1),
        ),
        selectedRecordId: catalog[1].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ),
    ];
    expect(changedInputs.every((next) => next.shouldRepaint(painter)), isTrue);
  });
}

SurgeryTrendChartLayout _layout({
  required AnalysisHorizontalAxisMode mode,
  required List<SurgeryAnalysisRecord> catalog,
  required List<SurgeryTrendPoint> points,
  CalendarDay reference = const CalendarDay(2028, 1, 1),
}) {
  return SurgeryTrendChartLayout.calculate(
    width: 360,
    height: 320,
    points: points,
    horizontalAxis: _axis(mode, catalog, reference),
    measureText: (value) => Size(value.length * 8, 14),
  );
}

AnalysisHorizontalAxis _axis(
  AnalysisHorizontalAxisMode mode,
  List<SurgeryAnalysisRecord> catalog,
  CalendarDay reference,
) {
  return AnalysisHorizontalAxis(
    mode: mode,
    catalog: catalog,
    referenceDate: reference,
  );
}

List<SurgeryAnalysisRecord> _catalog(int count) {
  return _catalogForDates([
    for (var index = 0; index < count; index++)
      DateTime(2026, 1, 1).add(Duration(days: index)),
  ]);
}

List<SurgeryAnalysisRecord> _catalogForDates(List<DateTime> dates) {
  return [
    for (var index = 0; index < dates.length; index++)
      SurgeryAnalysisRecord(
        recordId: 'r$index',
        surgeryDate: dates[index],
        createdAt: dates[index].add(Duration(minutes: index)),
        rawEyeSide: EyeSide.right.name,
        eyeSide: EyeSide.right,
        caseOrdinal: index + 1,
      ),
  ];
}

SurgeryTrendPoint _point(
  SurgeryAnalysisRecord record,
  Duration duration, {
  SurgicalStep step = SurgicalStep.totalSurgeryTime,
}) {
  return SurgeryTrendPoint(
    recordId: record.recordId,
    surgeryDate: record.surgeryDate,
    createdAt: record.createdAt,
    eyeSide: record.eyeSide!,
    step: step,
    duration: duration,
    caseOrdinal: record.caseOrdinal,
    registeredRecordCount: 1,
  );
}
