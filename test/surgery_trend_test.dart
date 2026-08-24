import 'package:cataract_surgery_note/src/domain/duration_formatters.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const calculator = SurgeryTrendCalculator();

  SurgeryAnalysisMeasurement measurement({
    required String id,
    required DateTime surgeryDate,
    DateTime? createdAt,
    SurgicalStep step = SurgicalStep.totalSurgeryTime,
    int? start = 0,
    int? end = 60000,
    EyeSide eyeSide = EyeSide.right,
  }) {
    return SurgeryAnalysisMeasurement(
      recordId: id,
      surgeryDate: surgeryDate,
      createdAt: createdAt ?? surgeryDate,
      eyeSide: eyeSide,
      step: step,
      startMilliseconds: start,
      endMilliseconds: end,
    );
  }

  test('手術日、作成日時、recordIdの順で安定して並べる', () {
    final date = DateTime(2026, 7, 20);
    final data = calculator.calculate([
      measurement(id: 'c', surgeryDate: date, createdAt: date),
      measurement(
        id: 'old',
        surgeryDate: DateTime(2025, 7, 20),
        createdAt: date,
      ),
      measurement(
        id: 'later',
        surgeryDate: date,
        createdAt: date.add(const Duration(minutes: 1)),
      ),
      measurement(id: 'b', surgeryDate: date, createdAt: date),
    ], SurgicalStep.totalSurgeryTime);

    expect(data.points.map((point) => point.recordId), [
      'old',
      'b',
      'c',
      'later',
    ]);
  });

  test('欠損、0秒、逆転した時間と別工程を除外する', () {
    final date = DateTime(2026, 7, 20);
    final data = calculator.calculate([
      measurement(id: 'valid', surgeryDate: date, start: 1000, end: 2500),
      measurement(id: 'missing-start', surgeryDate: date, start: null),
      measurement(id: 'missing-end', surgeryDate: date, end: null),
      measurement(id: 'zero', surgeryDate: date, start: 1000, end: 1000),
      measurement(id: 'reverse', surgeryDate: date, start: 2000, end: 1000),
      measurement(
        id: 'other-step',
        surgeryDate: date,
        step: SurgicalStep.capsulorhexis,
      ),
    ], SurgicalStep.totalSurgeryTime);

    expect(data.points, hasLength(1));
    expect(data.points.single.recordId, 'valid');
    expect(data.points.single.duration, const Duration(milliseconds: 1500));
  });

  test('最新値を除く直前最大5件をミリ秒精度で平均する', () {
    final measurements = <SurgeryAnalysisMeasurement>[];
    for (var index = 0; index < 7; index++) {
      measurements.add(
        measurement(
          id: '$index',
          surgeryDate: DateTime(2026, 7, index + 1),
          end: 1001 + index,
        ),
      );
    }

    final summary = calculator
        .calculate(measurements, SurgicalStep.totalSurgeryTime)
        .summary!;

    expect(summary.latest, const Duration(milliseconds: 1007));
    expect(summary.previousAverage, const Duration(milliseconds: 1004));
    expect(summary.difference, const Duration(milliseconds: 3));
    expect(summary.comparisonCount, 5);
  });

  test('過去データがない場合は平均と差を作らない', () {
    final summary = calculator.calculate([
      measurement(id: 'only', surgeryDate: DateTime(2026, 7, 20)),
    ], SurgicalStep.totalSurgeryTime).summary!;

    expect(summary.comparisonCount, 0);
    expect(summary.previousAverage, isNull);
    expect(summary.difference, isNull);
  });

  test('過去の有効データが5件未満なら実件数で平均する', () {
    final summary = calculator.calculate([
      measurement(id: 'first', surgeryDate: DateTime(2026, 7, 1), end: 1000),
      measurement(id: 'second', surgeryDate: DateTime(2026, 7, 2), end: 2000),
      measurement(id: 'latest', surgeryDate: DateTime(2026, 7, 3), end: 4000),
    ], SurgicalStep.totalSurgeryTime).summary!;

    expect(summary.comparisonCount, 2);
    expect(summary.previousAverage, const Duration(milliseconds: 1500));
    expect(summary.difference, const Duration(milliseconds: 2500));
  });

  test('総手術時間の欠損を個別工程から推定しない', () {
    final date = DateTime(2026, 7, 20);
    final data = calculator.calculate([
      measurement(
        id: 'case',
        surgeryDate: date,
        step: SurgicalStep.capsulorhexis,
        start: 1000,
        end: 10000,
      ),
      measurement(
        id: 'case',
        surgeryDate: date,
        step: SurgicalStep.nucleusRemoval,
        start: 11000,
        end: 30000,
      ),
    ], SurgicalStep.totalSurgeryTime);

    expect(data.points, isEmpty);
    expect(data.summary, isNull);
  });

  test('共通時間フォーマッターが未計測と符号を正しく表示する', () {
    expect(formatProcedureDuration(null), '未設定');
    expect(formatProcedureDuration(const Duration(seconds: 65)), '1分05秒');
    expect(formatMinutesSeconds(const Duration(seconds: 65)), '1:05');
    expect(formatSignedMinutesSeconds(const Duration(seconds: 5)), '+0:05');
    expect(formatSignedMinutesSeconds(const Duration(seconds: -5)), '-0:05');
  });

  test('SQLite INT64境界の差分をDuration生成前に安全に検証する', () {
    const int64Min = -9223372036854775808;
    const int64Max = 9223372036854775807;

    expect(procedureDurationBetween(int64Min, int64Max), isNull);
    expect(procedureDurationBetween(0, int64Max), isNull);
    expect(procedureDurationBetween(int64Min, 0), isNull);
    expect(
      procedureDurationBetween(int64Max - 1, int64Max),
      const Duration(milliseconds: 1),
    );
    expect(
      procedureDurationBetween(int64Min, int64Min + 1),
      const Duration(milliseconds: 1),
    );
  });

  test('Durationに格納可能なミリ秒境界だけを受け付ける', () {
    const maximumDurationMilliseconds = 9223372036854775;

    expect(
      procedureDurationBetween(0, maximumDurationMilliseconds),
      const Duration(milliseconds: maximumDurationMilliseconds),
    );
    expect(
      procedureDurationBetween(0, maximumDurationMilliseconds + 1),
      isNull,
    );
  });

  test('doubleの精度上限を超える有効値も平均を1ms単位で保持する', () {
    const maximumDurationMilliseconds = 9223372036854775;
    final data = calculator.calculate([
      for (var index = 0; index < 6; index++)
        measurement(
          id: '$index',
          surgeryDate: DateTime(2026, 7, index + 1),
          end: maximumDurationMilliseconds,
        ),
    ], SurgicalStep.totalSurgeryTime);

    expect(
      data.summary!.previousAverage,
      const Duration(milliseconds: maximumDurationMilliseconds),
    );
    expect(data.summary!.difference, Duration.zero);
    expect(data.summary!.comparisonCount, 5);
  });

  test('タイムライン表示はSQLite INT64境界でもオーバーフローしない', () {
    expect(
      formatTimelineMilliseconds(-9223372036854775808),
      '-153722867280912:55.8',
    );
    expect(
      formatTimelineMilliseconds(9223372036854775807),
      '153722867280912:55.8',
    );
  });
}
