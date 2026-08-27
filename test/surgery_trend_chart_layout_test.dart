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

  test('painterは両modeのlayout tick位置を描画commandへ使い入力差を判定する', () {
    final catalog = _catalog(3);
    final points = [
      for (final record in catalog)
        _point(record, Duration(seconds: record.caseOrdinal * 10)),
    ];
    for (final mode in AnalysisHorizontalAxisMode.values) {
      final layout = _layout(mode: mode, catalog: catalog, points: points);
      final commands = trendChartHorizontalTickPaintCommands(layout);
      expect(commands, hasLength(layout.horizontalTicks.length));
      for (var index = 0; index < commands.length; index++) {
        expect(commands[index].markStart.dx, layout.horizontalTicks[index].x);
        expect(commands[index].markStart.dy, layout.plotBottom);
        expect(commands[index].markEnd.dx, layout.horizontalTicks[index].x);
        expect(commands[index].markEnd.dy, layout.plotBottom + 5);
        expect(
          commands[index].label,
          layout.horizontalTicks[index].value.label,
        );
        expect(
          commands[index].labelOrigin,
          layout.horizontalTicks[index].labelBounds.topLeft,
        );
      }

      final painter = TrendChartPainter(
        points: points,
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

    final layout = _layout(
      mode: AnalysisHorizontalAxisMode.caseOrder,
      catalog: catalog,
      points: points,
    );
    final painter = TrendChartPainter(
      points: points,
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
          points: points,
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
        points: equivalentPoints,
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
        points: points,
        layout: layout,
        selectedRecordId: catalog[2].recordId,
        colorScheme: const ColorScheme.light(),
        textStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
      ).shouldRepaint(painter),
      isTrue,
    );
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

SurgeryTrendPoint _point(SurgeryAnalysisRecord record, Duration duration) {
  return SurgeryTrendPoint(
    recordId: record.recordId,
    surgeryDate: record.surgeryDate,
    createdAt: record.createdAt,
    eyeSide: record.eyeSide!,
    step: SurgicalStep.totalSurgeryTime,
    duration: duration,
    caseOrdinal: record.caseOrdinal,
    registeredRecordCount: 1,
  );
}
