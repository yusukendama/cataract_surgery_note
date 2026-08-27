import 'package:cataract_surgery_note/src/domain/analysis_horizontal_axis.dart';
import 'package:cataract_surgery_note/src/domain/calendar_day.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SurgeryAnalysisRecord record({
    required String id,
    required DateTime date,
    required int ordinal,
    DateTime? createdAt,
  }) {
    return SurgeryAnalysisRecord(
      recordId: id,
      surgeryDate: date,
      createdAt: createdAt ?? date,
      rawEyeSide: EyeSide.right.name,
      eyeSide: EyeSide.right,
      caseOrdinal: ordinal,
    );
  }

  group('CalendarDay', () {
    test('ordinalはDSTや時刻ではなく暦日の連続整数になる', () {
      final beforeDst = CalendarDay.fromDateTime(DateTime(2024, 3, 9, 23));
      final afterDst = CalendarDay.fromDateTime(DateTime(2024, 3, 10, 1));
      final next = CalendarDay.fromDateTime(DateTime(2024, 3, 11, 22));

      expect(afterDst.ordinal - beforeDst.ordinal, 1);
      expect(next.ordinal - afterDst.ordinal, 1);
      expect(
        CalendarDay(2024, 3, 1).ordinal - CalendarDay(2024, 2, 29).ordinal,
        1,
      );
      expect(
        CalendarDay(2025, 1, 1).ordinal - CalendarDay(2024, 12, 31).ordinal,
        1,
      );
    });

    test('月末と閏日の月・年移動をanchorから独立にclampする', () {
      const marchEnd = CalendarDay(2024, 3, 31);
      expect(marchEnd.addMonths(-1), const CalendarDay(2024, 2, 29));
      expect(marchEnd.addMonths(1), const CalendarDay(2024, 4, 30));
      expect(marchEnd.addMonths(2), const CalendarDay(2024, 5, 31));

      const leapDay = CalendarDay(2024, 2, 29);
      expect(leapDay.addYears(-1), const CalendarDay(2023, 2, 28));
      expect(leapDay.addYears(1), const CalendarDay(2025, 2, 28));
    });
  });

  group('AnalysisHorizontalAxis', () {
    test('症例順はR=1を中央、R>=2を1...Rへ置く', () {
      final only = record(id: 'only', date: DateTime(2026, 1, 1), ordinal: 1);
      final single = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.caseOrder,
        catalog: [only],
        referenceDate: const CalendarDay(2026, 1, 2),
      );
      expect(single.xRatioForRecord(only), 0.5);

      final records = [
        for (var index = 0; index < 100; index++)
          record(
            id: 'r$index',
            date: DateTime(2026, 1, 1).add(Duration(days: index)),
            ordinal: index + 1,
          ),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.caseOrder,
        catalog: records,
        referenceDate: const CalendarDay(2027, 1, 1),
      );
      expect(axis.xRatioForRecord(records.first), 0);
      expect(axis.xRatioForRecord(records.last), 1);
      expect(axis.xRatioForRecord(records[86]), closeTo(86 / 99, 1e-12));
    });

    test('R=2とR=50でも症例順domainの両端と連続順位を維持する', () {
      for (final count in [2, 50]) {
        final records = [
          for (var index = 0; index < count; index++)
            record(
              id: 'r$index',
              date: DateTime(2026, 1, 1).add(Duration(days: index)),
              ordinal: index + 1,
            ),
        ];
        final axis = AnalysisHorizontalAxis(
          mode: AnalysisHorizontalAxisMode.caseOrder,
          catalog: records,
          referenceDate: const CalendarDay(2027, 1, 1),
        );

        expect(records.map((item) => item.caseOrdinal), [
          for (var ordinal = 1; ordinal <= count; ordinal++) ordinal,
        ]);
        expect(axis.xRatioForRecord(records.first), 0);
        expect(axis.xRatioForRecord(records.last), 1);
      }
    });

    test('時系列domainは全catalogと基準日を含み将来日をclampしない', () {
      final records = [
        record(id: 'past', date: DateTime(2026, 1, 1), ordinal: 1),
        record(id: 'future', date: DateTime(2026, 1, 21), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2026, 1, 11),
      );

      expect(axis.domainStart, const CalendarDay(2026, 1, 1));
      expect(axis.domainEnd, const CalendarDay(2026, 1, 21));
      expect(axis.xRatioForRecord(records.first), 0);
      expect(axis.xRatioForRecord(records.last), 1);
      expect(
        (axis.referenceDate.ordinal - axis.domainStart.ordinal) /
            (axis.domainEnd.ordinal - axis.domainStart.ordinal),
        0.5,
      );
    });

    test('全件過去では最新症例から現在までの空白tailを残す', () {
      final records = [
        record(id: 'old', date: DateTime(2026, 1, 1), ordinal: 1),
        record(id: 'latest', date: DateTime(2026, 1, 6), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2026, 1, 11),
      );

      expect(axis.xRatioForRecord(records.last), 0.5);
      expect(axis.domainEnd, const CalendarDay(2026, 1, 11));
    });

    test('同日だけのdomainは全症例を中央へ置く', () {
      final records = [
        record(id: 'a', date: DateTime(2026, 1, 1), ordinal: 1),
        record(id: 'b', date: DateTime(2026, 1, 1), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2026, 1, 1),
      );
      expect(records.map(axis.xRatioForRecord), everyElement(0.5));
    });
  });

  group('tick candidates', () {
    test('症例順R=37・間隔10は1,10,20,30,37', () {
      final ticks = caseOrderTickCandidate(recordCount: 37, interval: 10)!;
      expect(ticks.map((tick) => tick.caseOrdinal), [1, 10, 20, 30, 37]);
    });

    test('症例順候補は巨大Rでも32件を超えて生成しない', () {
      expect(
        caseOrderTickCandidate(recordCount: 1000000000, interval: 1),
        isNull,
      );
      final ticks = caseOrderTickCandidate(
        recordCount: 1000000000,
        interval: 50000000,
      )!;
      expect(ticks.length, lessThanOrEqualTo(32));
      expect(ticks.first.caseOrdinal, 1);
      expect(ticks.last.caseOrdinal, 1000000000);
    });

    test('3月31日anchorの月tickはclampを累積しない', () {
      final records = [
        record(id: 'past', date: DateTime(2024, 1, 31), ordinal: 1),
        record(id: 'future', date: DateTime(2024, 5, 31), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2024, 3, 31),
      );
      final ticks = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.month, 1),
      )!;

      expect(
        ticks.map((tick) => tick.day),
        contains(const CalendarDay(2024, 2, 29)),
      );
      expect(
        ticks.map((tick) => tick.day),
        contains(const CalendarDay(2024, 4, 30)),
      );
      expect(
        ticks.map((tick) => tick.day),
        contains(const CalendarDay(2024, 5, 31)),
      );
      expect(
        ticks.map((tick) => tick.label),
        containsAll(['現在', '1か月前', '1か月後', '2か月後']),
      );
    });

    test('日・週・年tickは過去と未来をreference anchorで表す', () {
      final records = [
        record(id: 'past', date: DateTime(2023, 1, 1), ordinal: 1),
        record(id: 'future', date: DateTime(2027, 1, 1), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2025, 1, 1),
      );
      final weeks = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.week, 1),
      );
      expect(weeks, isNull, reason: '32件を超える候補は生成しない');

      final years = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, 1),
      )!;
      expect(
        years.map((tick) => tick.label),
        containsAll(['2年前', '1年前', '現在', '1年後', '2年後']),
      );
      expect(years.length, lessThanOrEqualTo(32));
    });

    test('日と週tickは現在を含み過去・未来の単位labelを正しく返す', () {
      final records = [
        record(id: 'past', date: DateTime(2026, 8, 20), ordinal: 1),
        record(id: 'future', date: DateTime(2026, 9, 3), ordinal: 2),
      ];
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: records,
        referenceDate: const CalendarDay(2026, 8, 27),
      );
      final days = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.day, 1),
      )!;
      final weeks = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.week, 1),
      )!;

      expect(days.map((tick) => tick.label), containsAll(['1日前', '現在', '1日後']));
      expect(weeks.map((tick) => tick.label), ['1週間前', '現在', '1週間後']);
    });

    test('数百年domainでも候補を32件以下に保つ', () {
      final axis = AnalysisHorizontalAxis(
        mode: AnalysisHorizontalAxisMode.chronological,
        catalog: [
          record(id: 'past', date: DateTime(1700, 1, 1), ordinal: 1),
          record(id: 'future', date: DateTime(2500, 1, 1), ordinal: 2),
        ],
        referenceDate: const CalendarDay(2026, 8, 27),
      );

      expect(
        chronologicalTickCandidate(
          axis: axis,
          interval: const AnalysisTimeTickInterval(
            AnalysisTimeTickUnit.year,
            20,
          ),
        ),
        isNull,
      );
      final ticks = chronologicalTickCandidate(
        axis: axis,
        interval: const AnalysisTimeTickInterval(AnalysisTimeTickUnit.year, 50),
      )!;
      expect(ticks.length, lessThanOrEqualTo(32));
      expect(ticks.any((tick) => tick.label == '現在'), isTrue);
    });
  });
}
