import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/features/analysis/duration_axis_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DurationAxisScale', () {
    test('総手術時間は5分刻みで0から最大値の次の目盛りまで表示する', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.totalSurgeryTime,
        maximumDuration: const Duration(minutes: 18, seconds: 42),
      );

      expect(axis.minimum, Duration.zero);
      expect(axis.interval, const Duration(minutes: 5));
      expect(axis.maximum, const Duration(minutes: 20));
      expect(axis.ticks.map(axis.labelFor), ['0分', '5分', '10分', '15分', '20分']);
    });

    test('総手術時間が目盛りと一致すると上に1目盛り分の余白を設ける', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.totalSurgeryTime,
        maximumDuration: const Duration(minutes: 20),
      );

      expect(axis.maximum, const Duration(minutes: 25));
    });

    test('3分未満の工程は30秒刻みにする', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.capsulorhexis,
        maximumDuration: const Duration(minutes: 2, seconds: 18),
      );

      expect(axis.interval, const Duration(seconds: 30));
      expect(axis.maximum, const Duration(minutes: 2, seconds: 30));
      expect(axis.ticks.map(axis.labelFor), [
        '0秒',
        '30秒',
        '1分',
        '1分30秒',
        '2分',
        '2分30秒',
      ]);
    });

    test('30秒目盛りと最大値が一致すると上に1目盛り分の余白を設ける', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.capsulorhexis,
        maximumDuration: const Duration(minutes: 2, seconds: 30),
      );

      expect(axis.maximum, const Duration(minutes: 3));
    });

    test('3分直前まではミリ秒精度で30秒刻みを維持する', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.capsulorhexis,
        maximumDuration: const Duration(
          minutes: 2,
          seconds: 59,
          milliseconds: 999,
        ),
      );

      expect(axis.interval, const Duration(seconds: 30));
      expect(axis.maximum, const Duration(minutes: 3));
    });

    test('3分以上の工程は1分刻みにする', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.nucleusRemoval,
        maximumDuration: const Duration(minutes: 4, seconds: 12),
      );

      expect(axis.interval, const Duration(minutes: 1));
      expect(axis.maximum, const Duration(minutes: 5));
      expect(axis.ticks.map(axis.labelFor), [
        '0分',
        '1分',
        '2分',
        '3分',
        '4分',
        '5分',
      ]);
    });

    test('3分ちょうどで1分刻みに切り替え上部余白を確保する', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.nucleusRemoval,
        maximumDuration: const Duration(minutes: 3),
      );

      expect(axis.interval, const Duration(minutes: 1));
      expect(axis.maximum, const Duration(minutes: 4));
    });

    test('データ点のミリ秒精度を丸めず縦位置へ変換する', () {
      final axis = DurationAxisScale.forMaximum(
        step: SurgicalStep.capsulorhexis,
        maximumDuration: const Duration(
          minutes: 2,
          seconds: 12,
          milliseconds: 345,
        ),
      );
      const duration = Duration(minutes: 1, seconds: 6, milliseconds: 789);

      expect(
        axis.ratioFor(duration),
        closeTo(duration.inMicroseconds / axis.maximum.inMicroseconds, 1e-12),
      );
      expect(axis.maximum, greaterThan(duration));
    });

    test('負の最大時間は受け付けない', () {
      expect(
        () => DurationAxisScale.forMaximum(
          step: SurgicalStep.capsulorhexis,
          maximumDuration: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });
}
