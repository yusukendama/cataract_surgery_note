import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_review_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StepRecordingStatus', () {
    SurgicalStepReview review({
      int? startMilliseconds,
      int? endMilliseconds,
      bool isSkipped = false,
    }) {
      return SurgicalStepReview(
        id: 'review',
        surgeryRecordId: 'record',
        step: SurgicalStep.hydrodissection,
        startMilliseconds: startMilliseconds,
        endMilliseconds: endMilliseconds,
        isSkipped: isSkipped,
        rating: StepRating.unreviewed,
        reflection: '',
        createdAt: DateTime(2026, 8, 16),
        updatedAt: DateTime(2026, 8, 16),
      );
    }

    test('正の所要時間がある工程だけをrecordedとする', () {
      final recorded = review(startMilliseconds: 1000, endMilliseconds: 2500);

      expect(recorded.recordingStatus, StepRecordingStatus.recorded);
      expect(recorded.duration, const Duration(milliseconds: 1500));
      expect(recorded.isProcessed, isTrue);
    });

    test('時刻を持たない明示的な記録なしをskippedとする', () {
      final skipped = review(isSkipped: true);

      expect(skipped.recordingStatus, StepRecordingStatus.skipped);
      expect(skipped.duration, isNull);
      expect(skipped.isProcessed, isTrue);
      expect(skipped.isNotStarted, isFalse);
    });

    test('未入力・部分入力・0秒・逆転時刻をunprocessedとする', () {
      final unprocessedReviews = <SurgicalStepReview>[
        review(),
        review(startMilliseconds: 1000),
        review(endMilliseconds: 2000),
        review(startMilliseconds: 1000, endMilliseconds: 1000),
        review(startMilliseconds: 2000, endMilliseconds: 1000),
      ];

      for (final item in unprocessedReviews) {
        expect(item.recordingStatus, StepRecordingStatus.unprocessed);
        expect(item.duration, isNull);
        expect(item.isProcessed, isFalse);
      }
    });

    test('不正な時刻が残る工程はskipフラグだけでskippedにしない', () {
      final inconsistent = <SurgicalStepReview>[
        review(startMilliseconds: 1000, isSkipped: true),
        review(endMilliseconds: 2000, isSkipped: true),
        review(startMilliseconds: 1000, endMilliseconds: 1000, isSkipped: true),
      ];

      for (final item in inconsistent) {
        expect(item.recordingStatus, StepRecordingStatus.unprocessed);
        expect(item.isProcessed, isFalse);
      }
    });
  });

  group('CaseTimingReviewStatus', () {
    const rules = SurgeryReviewRules();
    final allStepCount = activeIndividualSurgicalSteps.length;

    CaseTimingReviewStatus? calculate({
      int? reviewSchemaVersion = 1,
      Duration? totalSurgeryDuration,
      bool hasTotalSurgeryTimingInput = false,
      int processedStepCount = 0,
      bool hasIndividualStepInput = false,
    }) {
      return rules.calculateCaseStatus(
        reviewSchemaVersion: reviewSchemaVersion,
        totalSurgeryDuration: totalSurgeryDuration,
        hasTotalSurgeryTimingInput: hasTotalSurgeryTimingInput,
        processedStepCount: processedStepCount,
        hasIndividualStepInput: hasIndividualStepInput,
      );
    }

    test('新スキーマで入力痕跡がなければ未レビューとする', () {
      expect(calculate(), CaseTimingReviewStatus.notStarted);
    });

    test('総時間または個別工程に入力痕跡があればレビュー中とする', () {
      expect(
        calculate(hasTotalSurgeryTimingInput: true),
        CaseTimingReviewStatus.inProgress,
      );
      expect(
        calculate(hasIndividualStepInput: true),
        CaseTimingReviewStatus.inProgress,
      );
      expect(
        calculate(processedStepCount: 1, hasIndividualStepInput: true),
        CaseTimingReviewStatus.inProgress,
      );
    });

    test('全個別工程が処理済みでも正の総手術時間がなければ完了しない', () {
      expect(
        calculate(
          processedStepCount: allStepCount,
          hasIndividualStepInput: true,
        ),
        CaseTimingReviewStatus.inProgress,
      );
      expect(
        calculate(
          totalSurgeryDuration: Duration.zero,
          hasTotalSurgeryTimingInput: true,
          processedStepCount: allStepCount,
          hasIndividualStepInput: true,
        ),
        CaseTimingReviewStatus.inProgress,
      );
      expect(
        calculate(
          totalSurgeryDuration: const Duration(milliseconds: -1),
          hasTotalSurgeryTimingInput: true,
          processedStepCount: allStepCount,
          hasIndividualStepInput: true,
        ),
        CaseTimingReviewStatus.inProgress,
      );
    });

    test('正の総手術時間と全個別工程の処理済みを満たすと完了する', () {
      expect(
        calculate(
          totalSurgeryDuration: const Duration(minutes: 10),
          hasTotalSurgeryTimingInput: true,
          processedStepCount: allStepCount,
          hasIndividualStepInput: true,
        ),
        CaseTimingReviewStatus.completed,
      );
    });

    test('総手術時間が有効でも不足工程があればレビュー中とする', () {
      expect(
        calculate(
          totalSurgeryDuration: const Duration(minutes: 10),
          hasTotalSurgeryTimingInput: true,
          processedStepCount: allStepCount - 1,
          hasIndividualStepInput: true,
        ),
        CaseTimingReviewStatus.inProgress,
      );
    });

    test('旧症例は入力内容から状態を推測せず適用外とする', () {
      expect(
        calculate(
          reviewSchemaVersion: null,
          totalSurgeryDuration: const Duration(minutes: 10),
          hasTotalSurgeryTimingInput: true,
          processedStepCount: allStepCount,
          hasIndividualStepInput: true,
        ),
        isNull,
      );
    });
  });
}
