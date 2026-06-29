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
  capsulorhexis;

  String get label => switch (this) {
    SurgicalStep.capsulorhexis => 'CCC',
  };
}

class SurgeryRecord {
  const SurgeryRecord({
    required this.id,
    required this.surgeryDate,
    required this.eyeSide,
    required this.reviewStatus,
    required this.createdAt,
    required this.updatedAt,
    this.videoPath,
    this.videoDisplayName,
  });

  final String id;
  final DateTime surgeryDate;
  final EyeSide eyeSide;
  final ReviewStatus reviewStatus;

  /// New records store a managed video path relative to Application Support.
  /// Existing absolute paths are treated as legacy external references.
  final String? videoPath;
  final String? videoDisplayName;
  final DateTime createdAt;
  final DateTime updatedAt;

  SurgeryRecord copyWith({
    DateTime? surgeryDate,
    EyeSide? eyeSide,
    ReviewStatus? reviewStatus,
    String? videoPath,
    String? videoDisplayName,
    bool clearVideo = false,
    DateTime? updatedAt,
  }) {
    return SurgeryRecord(
      id: id,
      surgeryDate: surgeryDate ?? this.surgeryDate,
      eyeSide: eyeSide ?? this.eyeSide,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      videoPath: clearVideo ? null : videoPath ?? this.videoPath,
      videoDisplayName: clearVideo
          ? null
          : videoDisplayName ?? this.videoDisplayName,
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
  });

  final String id;
  final String surgeryRecordId;
  final SurgicalStep step;
  final int? startMilliseconds;
  final int? endMilliseconds;
  final StepRating rating;
  final String reflection;
  final DateTime createdAt;
  final DateTime updatedAt;

  Duration? get duration {
    final start = startMilliseconds;
    final end = endMilliseconds;
    if (start == null || end == null || end <= start) {
      return null;
    }
    return Duration(milliseconds: end - start);
  }

  SurgicalStepReview copyWith({
    int? startMilliseconds,
    int? endMilliseconds,
    StepRating? rating,
    String? reflection,
    DateTime? updatedAt,
    bool clearStart = false,
    bool clearEnd = false,
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
      rating: rating ?? this.rating,
      reflection: reflection ?? this.reflection,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
