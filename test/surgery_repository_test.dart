import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SurgeryRepository repository;

  setUp(() {
    repository = SurgeryRepository(AppDatabase.memory());
  });

  tearDown(() async {
    await repository.close();
  });

  test('症例保存と再取得', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 6, 29),
      eyeSide: EyeSide.right,
    );

    final restored = await repository.getRecord(record.id);

    expect(restored, isNotNull);
    expect(restored!.id, record.id);
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
}
