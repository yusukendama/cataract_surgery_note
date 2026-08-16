import 'surgery_models.dart';

class SurgeryReviewRules {
  const SurgeryReviewRules();

  CaseTimingReviewStatus? calculateCaseStatus({
    required int? reviewSchemaVersion,
    required Duration? totalSurgeryDuration,
    required bool hasTotalSurgeryTimingInput,
    required int processedStepCount,
    required bool hasIndividualStepInput,
  }) {
    if (reviewSchemaVersion != 1) {
      return null;
    }
    if (totalSurgeryDuration != null &&
        totalSurgeryDuration.inMicroseconds > 0 &&
        processedStepCount == activeIndividualSurgicalSteps.length) {
      return CaseTimingReviewStatus.completed;
    }
    if (!hasTotalSurgeryTimingInput &&
        !hasIndividualStepInput &&
        processedStepCount == 0) {
      return CaseTimingReviewStatus.notStarted;
    }
    return CaseTimingReviewStatus.inProgress;
  }
}
