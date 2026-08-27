import 'duration_formatters.dart';
import 'surgery_models.dart';

/// Classification of the time from the saved total-surgery start position to
/// an individual procedure's saved start position on the same video timeline.
enum ProcedureArrivalTimeStatus {
  available,
  notApplicable,
  skipped,
  stepStartMissing,
  totalSurgeryStartMissing,
  stepPositionInvalid,
  timelinePositionInvalid,
  totalSurgeryRangeInvalid,
  beforeTotalSurgeryStart,
  afterTotalSurgeryEnd,
  durationOutOfRange,
}

final class ProcedureArrivalTimeResult {
  const ProcedureArrivalTimeResult._({required this.status, this.duration})
    : assert(
        (status == ProcedureArrivalTimeStatus.available) == (duration != null),
      );

  const ProcedureArrivalTimeResult.available(Duration duration)
    : this._(status: ProcedureArrivalTimeStatus.available, duration: duration);

  const ProcedureArrivalTimeResult.status(ProcedureArrivalTimeStatus status)
    : this._(status: status);

  final ProcedureArrivalTimeStatus status;
  final Duration? duration;

  bool get isAvailable => status == ProcedureArrivalTimeStatus.available;
  bool get isApplicable => status != ProcedureArrivalTimeStatus.notApplicable;

  @override
  bool operator ==(Object other) {
    return other is ProcedureArrivalTimeResult &&
        other.status == status &&
        other.duration == duration;
  }

  @override
  int get hashCode => Object.hash(status, duration);
}

/// Calculates procedure arrival time without reading or mutating persistence.
///
/// The decision order intentionally mirrors the product requirements. In
/// particular, a target step's end position is used only to identify the
/// structural "end without start" state; once a valid start exists, its end
/// cannot invalidate the arrival time.
final class ProcedureArrivalTimeCalculator {
  const ProcedureArrivalTimeCalculator();

  ProcedureArrivalTimeResult calculate({
    required SurgicalStep step,
    required SurgicalStepReview? stepReview,
    required SurgicalStepReview? totalSurgeryReview,
  }) {
    if (!activeIndividualSurgicalSteps.contains(step)) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.notApplicable,
      );
    }

    if (stepReview?.recordingStatus == StepRecordingStatus.skipped) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.skipped,
      );
    }

    final stepStart = stepReview?.startMilliseconds;
    final stepEnd = stepReview?.endMilliseconds;
    if (stepStart == null && stepEnd != null) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.stepPositionInvalid,
      );
    }
    if (stepStart == null) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.stepStartMissing,
      );
    }

    final totalStart = totalSurgeryReview?.startMilliseconds;
    final totalEnd = totalSurgeryReview?.endMilliseconds;
    if (totalStart == null && totalEnd != null) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid,
      );
    }
    if (totalStart == null) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.totalSurgeryStartMissing,
      );
    }

    if (stepStart < 0 || totalStart < 0 || (totalEnd != null && totalEnd < 0)) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.timelinePositionInvalid,
      );
    }
    if (totalEnd != null && totalEnd <= totalStart) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.totalSurgeryRangeInvalid,
      );
    }
    if (stepStart < totalStart) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.beforeTotalSurgeryStart,
      );
    }
    if (totalEnd != null && stepStart > totalEnd) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.afterTotalSurgeryEnd,
      );
    }

    final difference = BigInt.from(stepStart) - BigInt.from(totalStart);
    if (difference > BigInt.from(maximumSafeDurationMilliseconds)) {
      return const ProcedureArrivalTimeResult.status(
        ProcedureArrivalTimeStatus.durationOutOfRange,
      );
    }
    return ProcedureArrivalTimeResult.available(
      Duration(milliseconds: difference.toInt()),
    );
  }
}
