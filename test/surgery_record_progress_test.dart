import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late SurgeryRepository repository;

  setUp(() {
    database = AppDatabase.memory();
    repository = SurgeryRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('工程進捗は正のdurationだけを完了へ数え総時間を独立表示する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);

    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.sidePortCreation)
          .id,
      start: 100,
      end: 200,
    );
    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.ovdInjection)
          .id,
      start: 300,
      end: null,
    );
    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.capsulorhexis)
          .id,
      start: 400,
      end: 400,
    );
    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.mainPortCreation)
          .id,
      start: 600,
      end: 500,
    );
    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.totalSurgeryTime)
          .id,
      start: 1000,
      end: 2500,
    );

    final progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.completedStepCount, 1);
    expect(progress.hasRunningStep, isTrue);
    expect(progress.totalSurgeryDuration, const Duration(milliseconds: 1500));
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.inProgress);
  });

  test('skippedを処理済みに数えるが総時間なしでは完了しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    for (final review in reviews.where(
      (review) => activeIndividualSurgicalSteps.contains(review.step),
    )) {
      await _setSkipped(database, review.id);
    }

    final progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.completedStepCount, activeIndividualSurgicalSteps.length);
    expect(progress.hasRunningStep, isFalse);
    expect(progress.totalSurgeryDuration, isNull);
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.inProgress);
  });

  test('0秒と逆転した総時間は完了条件を満たさない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final totalReview = reviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    for (final review in reviews.where(
      (review) => activeIndividualSurgicalSteps.contains(review.step),
    )) {
      await _setSkipped(database, review.id);
    }

    await _setTiming(database, totalReview.id, start: 900, end: 900);
    var progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.totalSurgeryDuration, isNull);
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.inProgress);

    await _setTiming(database, totalReview.id, start: 1000, end: 900);
    progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.totalSurgeryDuration, isNull);
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.inProgress);

    await _setTiming(database, totalReview.id, start: 1000, end: 2500);
    progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.totalSurgeryDuration, const Duration(milliseconds: 1500));
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.completed);
  });

  test('不足した現役工程行をunprocessedと扱い読み取りで補完しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final missingStep = activeIndividualSurgicalSteps.last;
    final missingReview = reviews.singleWhere(
      (review) => review.step == missingStep,
    );
    await database.customStatement(
      'DELETE FROM surgical_step_reviews WHERE id = ?',
      <Object?>[missingReview.id],
    );

    for (final review in reviews.where(
      (review) =>
          activeIndividualSurgicalSteps.contains(review.step) &&
          review.step != missingStep,
    )) {
      await _setSkipped(database, review.id);
    }
    final totalReview = reviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    await _setTiming(database, totalReview.id, start: 1000, end: 5000);

    final progress = (await repository.fetchRecordProgressSnapshots()).single;
    final rowsAfterRead = await database
        .customSelect(
          'SELECT COUNT(*) AS count FROM surgical_step_reviews '
          'WHERE surgery_record_id = ?',
          variables: [Variable<String>(record.id)],
        )
        .getSingle();

    expect(
      progress.completedStepCount,
      activeIndividualSurgicalSteps.length - 1,
    );
    expect(progress.timingReviewStatus, CaseTimingReviewStatus.inProgress);
    expect(
      rowsAfterRead.read<int>('count'),
      surgicalStepsInDisplayOrder.length - 1,
    );
  });

  test('旧schemaの症例は全時刻が揃ってもレビュー状態を推測しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    for (final review in reviews.where(
      (review) => activeIndividualSurgicalSteps.contains(review.step),
    )) {
      await _setSkipped(database, review.id);
    }
    final totalReview = reviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    await _setTiming(database, totalReview.id, start: 1000, end: 5000);
    await _setRecordCompatibilityFields(
      database,
      record.id,
      reviewStatus: ReviewStatus.reviewed,
      reviewSchemaVersion: null,
    );

    final progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.record.reviewSchemaVersion, isNull);
    expect(progress.record.reviewStatus, ReviewStatus.reviewed);
    expect(progress.completedStepCount, activeIndividualSurgicalSteps.length);
    expect(progress.totalSurgeryDuration, const Duration(milliseconds: 4000));
    expect(progress.timingReviewStatus, isNull);
  });

  test('新しいレビュー状態は既存reviewStatusに依存しない', () async {
    final completedRecord = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.right,
    );
    final completedReviews = await repository.ensureStepReviews(
      completedRecord.id,
    );
    for (final review in completedReviews.where(
      (review) => activeIndividualSurgicalSteps.contains(review.step),
    )) {
      await _setSkipped(database, review.id);
    }
    final totalReview = completedReviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    await _setTiming(database, totalReview.id, start: 1000, end: 5000);
    await _setRecordCompatibilityFields(
      database,
      completedRecord.id,
      reviewStatus: ReviewStatus.draft,
      reviewSchemaVersion: 1,
    );

    final notStartedRecord = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 14),
      eyeSide: EyeSide.left,
    );
    await _setRecordCompatibilityFields(
      database,
      notStartedRecord.id,
      reviewStatus: ReviewStatus.reviewed,
      reviewSchemaVersion: 1,
    );

    final snapshots = await repository.fetchRecordProgressSnapshots();
    final completed = snapshots.singleWhere(
      (snapshot) => snapshot.record.id == completedRecord.id,
    );
    final notStarted = snapshots.singleWhere(
      (snapshot) => snapshot.record.id == notStartedRecord.id,
    );

    expect(completed.record.reviewStatus, ReviewStatus.draft);
    expect(completed.timingReviewStatus, CaseTimingReviewStatus.completed);
    expect(notStarted.record.reviewStatus, ReviewStatus.reviewed);
    expect(notStarted.timingReviewStatus, CaseTimingReviewStatus.notStarted);
  });
}

Future<void> _setTiming(
  AppDatabase database,
  String reviewId, {
  required int? start,
  required int? end,
}) {
  return database.customStatement(
    '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?
WHERE id = ?
''',
    <Object?>[start, end, reviewId],
  );
}

Future<void> _setSkipped(AppDatabase database, String reviewId) {
  return database.customStatement(
    '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL, end_milliseconds = NULL, is_skipped = 1
WHERE id = ?
''',
    <Object?>[reviewId],
  );
}

Future<void> _setRecordCompatibilityFields(
  AppDatabase database,
  String recordId, {
  required ReviewStatus reviewStatus,
  required int? reviewSchemaVersion,
}) {
  return database.customStatement(
    '''
UPDATE surgery_records
SET review_status = ?, review_schema_version = ?
WHERE id = ?
''',
    <Object?>[reviewStatus.name, reviewSchemaVersion, recordId],
  );
}
