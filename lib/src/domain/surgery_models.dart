import 'duration_formatters.dart';

enum EyeSide {
  right,
  left;

  String get label => switch (this) {
    EyeSide.right => '右眼',
    EyeSide.left => '左眼',
  };
}

enum ReviewStatus {
  draft,
  reviewed;

  String get label => switch (this) {
    ReviewStatus.draft => '下書き',
    ReviewStatus.reviewed => 'レビュー済み',
  };
}

enum StepRecordingStatus { unprocessed, recorded, skipped }

enum CaseTimingReviewStatus { notStarted, inProgress, completed }

enum StepRating {
  unreviewed,
  good,
  fair,
  needsImprovement;

  String get label => switch (this) {
    StepRating.unreviewed => '未評価',
    StepRating.good => '良い',
    StepRating.fair => '普通',
    StepRating.needsImprovement => '要改善',
  };
}

enum SurgicalStep {
  totalSurgeryTime('total_surgery_time', '総手術時間'),

  /// Retained only so records saved by older app versions remain readable.
  subTenonAnesthesia('sub_tenon_anesthesia', 'テノン嚢下麻酔'),
  sidePortCreation('side_port_creation', 'サイドポート作成'),
  ovdInjection('ovd_injection', '粘弾性物質注入'),

  /// The legacy value is intentionally retained for existing CCC records.
  capsulorhexis('capsulorhexis', 'CCC'),
  mainPortCreation('main_port_creation', 'メインポート作成'),
  hydrodissection('hydrodissection', 'ハイドロダイセクション'),
  nucleusRemoval('nucleus_removal', '核処理'),
  corticalIrrigationAspiration('cortical_irrigation_aspiration', 'I/A'),
  iolInsertion('iol_insertion', 'IOL挿入'),
  ovdRemovalIrrigationAspiration(
    'ovd_removal_irrigation_aspiration',
    'I/A（粘弾性物質除去）',
  ),
  woundClosureAndPressureAdjustment(
    'wound_closure_and_pressure_adjustment',
    '創口閉鎖・圧調整',
  ),

  /// Retained only so records saved by older app versions remain readable.
  dexartSubconjunctivalInjection(
    'dexart_subconjunctival_injection',
    'デキサート結膜下注射',
  );

  const SurgicalStep(this.storageId, this.label);

  final String storageId;
  final String label;

  bool get isTotalSurgeryTime => this == SurgicalStep.totalSurgeryTime;

  bool canRunConcurrentlyWith(SurgicalStep other) {
    return this == other || isTotalSurgeryTime || other.isTotalSurgeryTime;
  }

  static SurgicalStep? fromStorageId(String storageId) {
    for (final step in values) {
      if (step.storageId == storageId) {
        return step;
      }
    }
    return null;
  }
}

/// Explicit display order, kept separate from enum declaration order.
const surgicalStepsInDisplayOrder = <SurgicalStep>[
  SurgicalStep.totalSurgeryTime,
  SurgicalStep.sidePortCreation,
  SurgicalStep.ovdInjection,
  SurgicalStep.capsulorhexis,
  SurgicalStep.mainPortCreation,
  SurgicalStep.hydrodissection,
  SurgicalStep.nucleusRemoval,
  SurgicalStep.corticalIrrigationAspiration,
  SurgicalStep.iolInsertion,
  SurgicalStep.ovdRemovalIrrigationAspiration,
  SurgicalStep.woundClosureAndPressureAdjustment,
];

const activeIndividualSurgicalSteps = <SurgicalStep>[
  SurgicalStep.sidePortCreation,
  SurgicalStep.ovdInjection,
  SurgicalStep.capsulorhexis,
  SurgicalStep.mainPortCreation,
  SurgicalStep.hydrodissection,
  SurgicalStep.nucleusRemoval,
  SurgicalStep.corticalIrrigationAspiration,
  SurgicalStep.iolInsertion,
  SurgicalStep.ovdRemovalIrrigationAspiration,
  SurgicalStep.woundClosureAndPressureAdjustment,
];

class SurgeryRecord {
  const SurgeryRecord({
    required this.id,
    required this.surgeryDate,
    required this.eyeSide,
    required this.reviewStatus,
    required this.createdAt,
    required this.updatedAt,
    this.reviewSchemaVersion,
    this.videoPath,
    this.videoDisplayName,
    this.caseMemo = '',
  });

  final String id;
  final DateTime surgeryDate;
  final EyeSide eyeSide;
  final ReviewStatus reviewStatus;

  /// Null identifies records created before timing-review completion tracking.
  final int? reviewSchemaVersion;

  /// New records store a managed video path relative to Application Support.
  /// Existing absolute paths are treated as legacy external references.
  final String? videoPath;
  final String? videoDisplayName;
  final String caseMemo;
  final DateTime createdAt;
  final DateTime updatedAt;

  SurgeryRecord copyWith({
    DateTime? surgeryDate,
    EyeSide? eyeSide,
    ReviewStatus? reviewStatus,
    int? reviewSchemaVersion,
    String? videoPath,
    String? videoDisplayName,
    bool clearVideo = false,
    String? caseMemo,
    DateTime? updatedAt,
  }) {
    return SurgeryRecord(
      id: id,
      surgeryDate: surgeryDate ?? this.surgeryDate,
      eyeSide: eyeSide ?? this.eyeSide,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reviewSchemaVersion: reviewSchemaVersion ?? this.reviewSchemaVersion,
      videoPath: clearVideo ? null : videoPath ?? this.videoPath,
      videoDisplayName: clearVideo
          ? null
          : videoDisplayName ?? this.videoDisplayName,
      caseMemo: caseMemo ?? this.caseMemo,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class SurgicalStepReview {
  const SurgicalStepReview({
    required this.id,
    required this.surgeryRecordId,
    required this.step,
    required this.rating,
    required this.reflection,
    required this.createdAt,
    required this.updatedAt,
    this.startMilliseconds,
    this.endMilliseconds,
    this.isSkipped = false,
  });

  final String id;
  final String surgeryRecordId;
  final SurgicalStep step;
  final int? startMilliseconds;
  final int? endMilliseconds;
  final bool isSkipped;
  final StepRating rating;
  final String reflection;
  final DateTime createdAt;
  final DateTime updatedAt;

  Duration? get duration {
    return procedureDurationBetween(startMilliseconds, endMilliseconds);
  }

  bool get isNotStarted =>
      recordingStatus == StepRecordingStatus.unprocessed &&
      startMilliseconds == null &&
      endMilliseconds == null;

  bool get isRunning => startMilliseconds != null && endMilliseconds == null;

  bool get isCompleted => duration != null;

  bool get isProcessed =>
      recordingStatus == StepRecordingStatus.recorded ||
      recordingStatus == StepRecordingStatus.skipped;

  StepRecordingStatus get recordingStatus {
    if (duration != null) {
      return StepRecordingStatus.recorded;
    }
    if (startMilliseconds == null && endMilliseconds == null && isSkipped) {
      return StepRecordingStatus.skipped;
    }
    return StepRecordingStatus.unprocessed;
  }

  SurgicalStepReview copyWith({
    int? startMilliseconds,
    int? endMilliseconds,
    StepRating? rating,
    String? reflection,
    DateTime? updatedAt,
    bool clearStart = false,
    bool clearEnd = false,
    bool? isSkipped,
  }) {
    return SurgicalStepReview(
      id: id,
      surgeryRecordId: surgeryRecordId,
      step: step,
      startMilliseconds: clearStart
          ? null
          : startMilliseconds ?? this.startMilliseconds,
      endMilliseconds: clearEnd
          ? null
          : endMilliseconds ?? this.endMilliseconds,
      isSkipped: isSkipped ?? this.isSkipped,
      rating: rating ?? this.rating,
      reflection: reflection ?? this.reflection,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
