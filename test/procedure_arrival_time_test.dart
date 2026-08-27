import 'package:cataract_surgery_note/src/domain/duration_formatters.dart';
import 'package:cataract_surgery_note/src/domain/procedure_arrival_time.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const calculator = ProcedureArrivalTimeCalculator();

  SurgicalStepReview review({
    required SurgicalStep step,
    int? start,
    int? end,
    bool isSkipped = false,
  }) {
    return SurgicalStepReview(
      id: '${step.name}-review',
      surgeryRecordId: 'record',
      step: step,
      startMilliseconds: start,
      endMilliseconds: end,
      isSkipped: isSkipped,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  SurgicalStepReview target({
    int? start,
    int? end,
    bool isSkipped = false,
    SurgicalStep step = SurgicalStep.nucleusRemoval,
  }) => review(step: step, start: start, end: end, isSkipped: isSkipped);

  SurgicalStepReview total({int? start, int? end}) =>
      review(step: SurgicalStep.totalSurgeryTime, start: start, end: end);

  ProcedureArrivalTimeResult calculate({
    SurgicalStep step = SurgicalStep.nucleusRemoval,
    SurgicalStepReview? targetReview,
    SurgicalStepReview? totalReview,
  }) => calculator.calculate(
    step: step,
    stepReview: targetReview,
    totalSurgeryReview: totalReview,
  );

  group('ProcedureArrivalTimeCalculator', () {
    test('総手術開始と対象工程開始の直接差分を返す', () {
      final result = calculate(
        targetReview: target(start: 220000, end: 280000),
        totalReview: total(start: 30000, end: 400000),
      );

      expect(result.status, ProcedureArrivalTimeStatus.available);
      expect(result.duration, const Duration(minutes: 3, seconds: 10));
    });

    test('総手術開始と工程開始が同じなら0ミリ秒を正常値にする', () {
      expect(
        calculate(
          targetReview: target(start: 60000),
          totalReview: total(start: 60000, end: 120000),
        ),
        const ProcedureArrivalTimeResult.available(Duration.zero),
      );
    });

    test('対象工程終了位置は開始があれば到達時間へ影響しない', () {
      const int64Min = -9223372036854775808;
      const int64Max = 9223372036854775807;
      for (final end in <int?>[
        null,
        249999,
        250000,
        300000,
        -1,
        int64Min,
        int64Max,
      ]) {
        expect(
          calculate(
            targetReview: target(start: 250000, end: end),
            totalReview: total(start: 30000),
          ),
          const ProcedureArrivalTimeResult.available(
            Duration(milliseconds: 220000),
          ),
          reason: 'target end: $end',
        );
      }
    });

    test('正常な時間記録なしを未登録と区別する', () {
      final result = calculate(
        targetReview: target(isSkipped: true),
        totalReview: total(start: 30000, end: 400000),
      );

      expect(result.status, ProcedureArrivalTimeStatus.skipped);
      expect(result.duration, isNull);
    });

    test('raw skipと有効な開始終了が併存すれば既存正規化どおり記録済みにする', () {
      final result = calculate(
        targetReview: target(start: 250000, end: 300000, isSkipped: true),
        totalReview: total(start: 30000),
      );

      expect(
        result,
        const ProcedureArrivalTimeResult.available(
          Duration(milliseconds: 220000),
        ),
      );
    });

    test('raw skipと開始だけが併存しても開始位置から算出する', () {
      final result = calculate(
        targetReview: target(start: 250000, isSkipped: true),
        totalReview: total(start: 30000),
      );

      expect(result.status, ProcedureArrivalTimeStatus.available);
      expect(result.duration, const Duration(milliseconds: 220000));
    });

    test('対象工程行なしと開始終了なしを工程開始未登録にする', () {
      for (final targetReview in <SurgicalStepReview?>[null, target()]) {
        expect(
          calculate(
            targetReview: targetReview,
            totalReview: total(start: 30000),
          ).status,
          ProcedureArrivalTimeStatus.stepStartMissing,
        );
      }
    });

    test('開始なし終了ありを工程位置不整合にする', () {
      expect(
        calculate(
          targetReview: target(end: 250000),
          totalReview: total(start: 30000),
        ).status,
        ProcedureArrivalTimeStatus.stepPositionInvalid,
      );
    });

    test('総手術行なしまたは開始終了なしを総手術開始未登録にする', () {
      for (final totalReview in <SurgicalStepReview?>[null, total()]) {
        expect(
          calculate(
            targetReview: target(start: 250000),
            totalReview: totalReview,
          ).status,
          ProcedureArrivalTimeStatus.totalSurgeryStartMissing,
        );
      }
    });

    test('総手術開始なし終了ありを総手術範囲不正にする', () {
      expect(
        calculate(
          targetReview: target(start: 250000),
          totalReview: total(end: 400000),
        ).status,
        ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid,
      );
    });

    test('総手術終了未登録なら上限検証を省略する', () {
      expect(
        calculate(
          targetReview: target(start: 900000),
          totalReview: total(start: 30000),
        ).status,
        ProcedureArrivalTimeStatus.available,
      );
    });

    test('工程開始が総手術開始前なら負値を返さない', () {
      final result = calculate(
        targetReview: target(start: 50000),
        totalReview: total(start: 60000, end: 120000),
      );

      expect(result.status, ProcedureArrivalTimeStatus.beforeTotalSurgeryStart);
      expect(result.duration, isNull);
    });

    test('工程開始は総手術終了と同値まで正常で1ミリ秒後は不整合', () {
      expect(
        calculate(
          targetReview: target(start: 250000),
          totalReview: total(start: 30000, end: 250000),
        ).status,
        ProcedureArrivalTimeStatus.available,
      );
      expect(
        calculate(
          targetReview: target(start: 250001),
          totalReview: total(start: 30000, end: 250000),
        ).status,
        ProcedureArrivalTimeStatus.afterTotalSurgeryEnd,
      );
    });

    test('総手術終了が開始と同じか前なら総手術範囲不正', () {
      for (final end in [30000, 29999]) {
        expect(
          calculate(
            targetReview: target(start: 50000),
            totalReview: total(start: 30000, end: end),
          ).status,
          ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid,
        );
      }
    });

    test('算出に使用する各絶対位置の負値を不正とする', () {
      final fixtures =
          <({SurgicalStepReview target, SurgicalStepReview total})>[
            (target: target(start: -1), total: total(start: 0)),
            (target: target(start: 10), total: total(start: -1)),
            (target: target(start: 10), total: total(start: 0, end: -1)),
          ];
      for (final fixture in fixtures) {
        expect(
          calculate(
            targetReview: fixture.target,
            totalReview: fixture.total,
          ).status,
          ProcedureArrivalTimeStatus.timelinePositionInvalid,
        );
      }
    });

    test('Duration保持上限ちょうどを許可し1ミリ秒超過を拒否する', () {
      expect(
        calculate(
          targetReview: target(start: maximumSafeDurationMilliseconds),
          totalReview: total(start: 0),
        ),
        const ProcedureArrivalTimeResult.available(
          Duration(milliseconds: maximumSafeDurationMilliseconds),
        ),
      );
      expect(
        calculate(
          targetReview: target(start: maximumSafeDurationMilliseconds + 1),
          totalReview: total(start: 0),
        ).status,
        ProcedureArrivalTimeStatus.durationOutOfRange,
      );
    });

    test('SQLite INT64境界をオーバーフローせず分類する', () {
      const int64Min = -9223372036854775808;
      const int64Max = 9223372036854775807;

      expect(
        calculate(
          targetReview: target(start: int64Max),
          totalReview: total(start: 0),
        ).status,
        ProcedureArrivalTimeStatus.durationOutOfRange,
      );
      expect(
        calculate(
          targetReview: target(start: int64Max),
          totalReview: total(start: int64Min),
        ).status,
        ProcedureArrivalTimeStatus.timelinePositionInvalid,
      );
      expect(
        calculate(
          targetReview: target(start: int64Max),
          totalReview: total(start: int64Max),
        ),
        const ProcedureArrivalTimeResult.available(Duration.zero),
      );
    });

    test('総手術時間・非表示legacy工程を対象外にする', () {
      for (final step in [
        SurgicalStep.totalSurgeryTime,
        SurgicalStep.subTenonAnesthesia,
        SurgicalStep.dexartSubconjunctivalInjection,
      ]) {
        expect(
          calculate(
            step: step,
            targetReview: target(step: step, start: 30000),
            totalReview: total(start: 30000),
          ).status,
          ProcedureArrivalTimeStatus.notApplicable,
        );
      }
    });

    test('現行10工程はすべて対象になる', () {
      for (final step in activeIndividualSurgicalSteps) {
        expect(
          calculate(
            step: step,
            targetReview: target(step: step, start: 31000),
            totalReview: total(start: 30000),
          ).status,
          ProcedureArrivalTimeStatus.available,
        );
      }
    });

    test('対象外・skip・工程未登録を総手術側の不整合より優先する', () {
      final corruptTotal = total(start: -1, end: -2);
      expect(
        calculate(
          step: SurgicalStep.totalSurgeryTime,
          targetReview: total(start: -1, end: -2),
          totalReview: corruptTotal,
        ).status,
        ProcedureArrivalTimeStatus.notApplicable,
      );
      expect(
        calculate(
          targetReview: target(isSkipped: true),
          totalReview: corruptTotal,
        ).status,
        ProcedureArrivalTimeStatus.skipped,
      );
      expect(
        calculate(targetReview: target(), totalReview: corruptTotal).status,
        ProcedureArrivalTimeStatus.stepStartMissing,
      );
      expect(
        calculate(
          targetReview: target(end: -1),
          totalReview: corruptTotal,
        ).status,
        ProcedureArrivalTimeStatus.stepPositionInvalid,
      );
    });

    test('総手術開始なし終了ありを工程開始の負値より優先する', () {
      expect(
        calculate(
          targetReview: target(start: -1),
          totalReview: total(end: 1000),
        ).status,
        ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid,
      );
    });
  });

  group('formatProcedureArrivalDuration', () {
    final fixtures = <Duration, String>{
      Duration.zero: '0秒',
      const Duration(milliseconds: 999): '0秒',
      const Duration(milliseconds: 59999): '59秒',
      const Duration(milliseconds: 60000): '1分00秒',
      const Duration(milliseconds: 222999): '3分42秒',
      const Duration(milliseconds: 3599999): '59分59秒',
      const Duration(milliseconds: 3600000): '1時間00分00秒',
      const Duration(milliseconds: 3735999): '1時間02分15秒',
    };

    for (final entry in fixtures.entries) {
      test('${entry.key.inMilliseconds}ミリ秒を${entry.value}で表示する', () {
        expect(formatProcedureArrivalDuration(entry.key), entry.value);
      });
    }

    test('各入力でなく差分後のミリ秒を切り捨てる形式を保つ', () {
      final result = calculator.calculate(
        step: SurgicalStep.nucleusRemoval,
        stepReview: target(start: 31100),
        totalSurgeryReview: total(start: 30900),
      );

      expect(result.duration, const Duration(milliseconds: 200));
      expect(formatProcedureArrivalDuration(result.duration!), '0秒');
    });

    test('負値を通常表示へ変換しない', () {
      expect(
        () => formatProcedureArrivalDuration(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });
  });
}
