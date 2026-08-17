import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:cataract_surgery_note/src/domain/surgery_trend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late SurgeryRepository repository;

  setUp(() {
    database = AppDatabase.memory();
    repository = SurgeryRepository(database);
  });

  tearDown(() async {
    await repository.close();
  });

  test('症例の内容を読み込まず存在有無を判定する', () async {
    expect(await repository.hasAnyRecords(), isFalse);

    await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 17),
      eyeSide: EyeSide.right,
    );

    expect(await repository.hasAnyRecords(), isTrue);
  });

  test('新規症例は作成直後と再取得後ともレビューschema version 1である', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.right,
    );

    expect(record.reviewSchemaVersion, 1);

    final restored = await repository.getRecord(record.id);

    expect(restored, isNotNull);
    expect(restored!.id, record.id);
    expect(restored.reviewSchemaVersion, 1);
    expect(restored.eyeSide, EyeSide.right);
    expect(restored.surgeryDate.year, 2026);
    expect(restored.surgeryDate.month, 6);
    expect(restored.surgeryDate.day, 29);
  });

  test('CCCレビュー保存と再取得', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.left,
    );
    final review = await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );

    await repository.saveStepReview(
      review.copyWith(
        startMilliseconds: 1000,
        endMilliseconds: 5000,
        rating: StepRating.fair,
        reflection: '前嚢切開の中心がやや鼻側。',
      ),
    );
    final restored = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );

    expect(restored, isNotNull);
    expect(restored!.startMilliseconds, 1000);
    expect(restored.endMilliseconds, 5000);
    expect(restored.duration, const Duration(seconds: 4));
    expect(restored.rating, StepRating.fair);
    expect(restored.reflection, '前嚢切開の中心がやや鼻側。');
  });

  test('11項目を保存し再取得できる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);

    expect(reviews, hasLength(11));
    expect(reviews.map((item) => item.step), surgicalStepsInDisplayOrder);

    final nucleus = reviews.firstWhere(
      (item) => item.step == SurgicalStep.nucleusRemoval,
    );
    await repository.saveStepReview(
      nucleus.copyWith(startMilliseconds: 10000, endMilliseconds: 15000),
    );

    final restored = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.nucleusRemoval,
    );
    expect(restored!.duration, const Duration(seconds: 5));
  });

  test('対象工程の再設定がほかの工程へ影響しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.left,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final ia = reviews.firstWhere(
      (item) => item.step == SurgicalStep.corticalIrrigationAspiration,
    );
    final ovdRemoval = reviews.firstWhere(
      (item) => item.step == SurgicalStep.ovdRemovalIrrigationAspiration,
    );
    await repository.saveStepReview(
      ia.copyWith(startMilliseconds: 1000, endMilliseconds: 2000),
    );
    await repository.saveStepReview(
      ovdRemoval.copyWith(startMilliseconds: 3000, endMilliseconds: 5000),
    );

    final savedIa = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.corticalIrrigationAspiration,
    );
    await repository.saveStepReview(
      savedIa!.copyWith(clearStart: true, clearEnd: true),
    );

    final resetIa = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.corticalIrrigationAspiration,
    );
    final preservedOvdRemoval = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.ovdRemovalIrrigationAspiration,
    );
    expect(resetIa!.isNotStarted, isTrue);
    expect(preservedOvdRemoval!.duration, const Duration(seconds: 2));
  });

  test('既存CCCの永続化IDをそのまま読み込める', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );
    final ccc = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );

    expect(ccc, isNotNull);
    expect(ccc!.step.storageId, 'capsulorhexis');
    expect((await repository.ensureStepReviews(record.id)), hasLength(11));
  });

  test('動画情報を保存・更新・クリアできる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );

    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: 'videos/${record.id}/abc.mp4',
      videoDisplayName: 'surgery.mp4',
    );
    final withVideo = await repository.getRecord(record.id);
    expect(withVideo!.videoPath, 'videos/${record.id}/abc.mp4');
    expect(withVideo.videoDisplayName, 'surgery.mp4');

    await repository.updateVideoReference(
      surgeryRecordId: record.id,
      videoPath: null,
      videoDisplayName: null,
    );
    final cleared = await repository.getRecord(record.id);
    expect(cleared!.videoPath, isNull);
    expect(cleared.videoDisplayName, isNull);
  });

  test('症例メモを保存・再取得できる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.left,
    );
    expect(record.caseMemo, '');

    await repository.updateCaseMemo(
      surgeryRecordId: record.id,
      caseMemo: '第一助手あり。',
    );

    final restored = await repository.getRecord(record.id);
    expect(restored!.caseMemo, '第一助手あり。');
  });

  test('手術日と左右眼を修正できる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );

    await repository.updateRecordDetails(
      surgeryRecordId: record.id,
      surgeryDate: DateTime(2026, 7, 18, 13, 45),
      eyeSide: EyeSide.left,
    );

    final restored = await repository.getRecord(record.id);
    expect(restored!.eyeSide, EyeSide.left);
    expect(restored.surgeryDate.year, 2026);
    expect(restored.surgeryDate.month, 7);
    expect(restored.surgeryDate.day, 18);
    expect(restored.surgeryDate.hour, 0);
    expect(restored.updatedAt.isAfter(record.updatedAt), isTrue);
  });

  test('clearStepTimingsで全工程の開始・終了のみクリアされる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final nucleus = reviews.firstWhere(
      (item) => item.step == SurgicalStep.nucleusRemoval,
    );
    await repository.saveStepReview(
      nucleus.copyWith(
        startMilliseconds: 1000,
        endMilliseconds: 5000,
        rating: StepRating.good,
        reflection: '核は軟らかめだった。',
      ),
    );

    await repository.clearStepTimings(record.id);

    final restored = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.nucleusRemoval,
    );
    expect(restored!.startMilliseconds, isNull);
    expect(restored.endMilliseconds, isNull);
    expect(restored.rating, StepRating.good);
    expect(restored.reflection, '核は軟らかめだった。');
  });

  test('分析用取得は工程を追加せず必要な情報だけを返す', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );
    final before = await database
        .customSelect('SELECT COUNT(*) AS count FROM surgical_step_reviews')
        .getSingle();

    final snapshot = await repository.fetchAnalysisSnapshot();
    final after = await database
        .customSelect('SELECT COUNT(*) AS count FROM surgical_step_reviews')
        .getSingle();

    expect(snapshot.recordCount, 1);
    expect(snapshot.measurements, hasLength(1));
    expect(snapshot.measurements.single.recordId, record.id);
    expect(snapshot.measurements.single.step, SurgicalStep.capsulorhexis);
    expect(after.read<int>('count'), before.read<int>('count'));
  });

  test('分析用取得は未知および旧工程IDを安全に除外する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.left,
    );
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await database.customStatement(
      '''
INSERT INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        'unknown-review',
        record.id,
        'unknown_future_step',
        1000,
        2000,
        StepRating.unreviewed.name,
        '',
        now,
        now,
      ],
    );
    await database.customStatement(
      '''
INSERT INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        'legacy-review',
        record.id,
        SurgicalStep.subTenonAnesthesia.storageId,
        1000,
        2000,
        StepRating.unreviewed.name,
        '',
        now,
        now,
      ],
    );

    final snapshot = await repository.fetchAnalysisSnapshot();

    expect(snapshot.recordCount, 1);
    expect(snapshot.measurements, hasLength(1));
    expect(snapshot.measurements.single.step, SurgicalStep.capsulorhexis);
  });

  test('分析用取得は下書きとレビュー済みの両方を対象にする', () async {
    final draft = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 14),
      eyeSide: EyeSide.right,
    );
    final reviewed = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.left,
    );
    final draftTotal = await repository.ensureStepReview(
      surgeryRecordId: draft.id,
      step: SurgicalStep.totalSurgeryTime,
    );
    final reviewedTotal = await repository.ensureStepReview(
      surgeryRecordId: reviewed.id,
      step: SurgicalStep.totalSurgeryTime,
    );
    await repository.saveStepReview(
      reviewedTotal.copyWith(startMilliseconds: 0, endMilliseconds: 60000),
    );
    await database.customStatement(
      '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?
WHERE id = ?
''',
      [0, 70000, draftTotal.id],
    );

    final snapshot = await repository.fetchAnalysisSnapshot();
    final totals = snapshot.measurements.where(
      (measurement) => measurement.step == SurgicalStep.totalSurgeryTime,
    );

    expect(totals.map((measurement) => measurement.recordId).toSet(), {
      draft.id,
      reviewed.id,
    });
    expect(
      (await repository.getRecord(draft.id))!.reviewStatus,
      ReviewStatus.draft,
    );
    expect(
      (await repository.getRecord(reviewed.id))!.reviewStatus,
      ReviewStatus.reviewed,
    );
  });

  test('skipped工程は0秒にならずチャート点と平均へ混入しない', () async {
    final previous = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 13),
      eyeSide: EyeSide.right,
    );
    final skipped = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 14),
      eyeSide: EyeSide.left,
    );
    final latest = await repository.createRecord(
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
    );

    final previousReview = await repository.getStepReview(
      surgeryRecordId: previous.id,
      step: SurgicalStep.capsulorhexis,
    );
    await repository.saveStepReview(
      previousReview!.copyWith(startMilliseconds: 1000, endMilliseconds: 11000),
    );

    final skippedReview = await repository.getStepReview(
      surgeryRecordId: skipped.id,
      step: SurgicalStep.capsulorhexis,
    );
    final timedSkippedReview = await repository.saveStepReview(
      skippedReview!.copyWith(startMilliseconds: 2000, endMilliseconds: 22000),
    );
    await repository.saveStepSkipped(
      review: timedSkippedReview,
      isSkipped: true,
      expectedVideoPath: null,
    );

    final latestReview = await repository.getStepReview(
      surgeryRecordId: latest.id,
      step: SurgicalStep.capsulorhexis,
    );
    await repository.saveStepReview(
      latestReview!.copyWith(startMilliseconds: 3000, endMilliseconds: 33000),
    );

    final persistedSkipped = await repository.getStepReview(
      surgeryRecordId: skipped.id,
      step: SurgicalStep.capsulorhexis,
    );
    expect(persistedSkipped!.isSkipped, isTrue);
    expect(persistedSkipped.startMilliseconds, isNull);
    expect(persistedSkipped.endMilliseconds, isNull);
    expect(persistedSkipped.duration, isNull);

    final snapshot = await repository.fetchAnalysisSnapshot();
    final measurements = snapshot.measurements.where(
      (measurement) => measurement.step == SurgicalStep.capsulorhexis,
    );

    expect(measurements.map((measurement) => measurement.recordId), [
      previous.id,
      skipped.id,
      latest.id,
    ]);
    expect(measurements.map((measurement) => measurement.duration), [
      const Duration(seconds: 10),
      null,
      const Duration(seconds: 30),
    ]);
    expect(
      measurements.any((measurement) => measurement.duration == Duration.zero),
      isFalse,
    );

    final trend = const SurgeryTrendCalculator().calculate(
      snapshot.measurements,
      SurgicalStep.capsulorhexis,
    );

    expect(trend.points.map((point) => point.recordId), [
      previous.id,
      latest.id,
    ]);
    expect(trend.points.map((point) => point.duration), [
      const Duration(seconds: 10),
      const Duration(seconds: 30),
    ]);
    expect(trend.summary, isNotNull);
    expect(trend.summary!.latest, const Duration(seconds: 30));
    expect(trend.summary!.previousAverage, const Duration(seconds: 10));
    expect(trend.summary!.difference, const Duration(seconds: 20));
    expect(trend.summary!.comparisonCount, 1);
  });
}
