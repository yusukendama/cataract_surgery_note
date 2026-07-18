import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SurgicalStepReview review({int? start, int? end}) {
    return SurgicalStepReview(
      id: 'review',
      surgeryRecordId: 'record',
      step: SurgicalStep.nucleusRemoval,
      startMilliseconds: start,
      endMilliseconds: end,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  test('12工程のIDが一意で表示順が固定されている', () {
    expect(surgicalStepsInDisplayOrder, hasLength(12));
    expect(
      surgicalStepsInDisplayOrder.map((step) => step.storageId).toSet(),
      hasLength(12),
    );
    expect(surgicalStepsInDisplayOrder.first.label, 'テノン嚢下麻酔');
    expect(surgicalStepsInDisplayOrder.last.label, 'デキサート結膜下注射');
    expect(
      SurgicalStep.corticalIrrigationAspiration.storageId,
      isNot(SurgicalStep.ovdRemovalIrrigationAspiration.storageId),
    );
  });

  test('永続化IDから工程を安全に復元する', () {
    expect(
      SurgicalStep.fromStorageId('capsulorhexis'),
      SurgicalStep.capsulorhexis,
    );
    expect(SurgicalStep.fromStorageId('unknown_future_step'), isNull);
  });

  test('未開始、計測中、完了と所要時間を判定する', () {
    expect(review().isNotStarted, isTrue);
    expect(review(start: 1000).isRunning, isTrue);
    expect(review(start: 1000, end: 4500).isCompleted, isTrue);
    expect(
      review(start: 1000, end: 4500).duration,
      const Duration(milliseconds: 3500),
    );
  });

  test('欠損または逆転した時刻から不正な所要時間を返さない', () {
    expect(review(start: null, end: 1000).duration, isNull);
    expect(review(start: 1000, end: null).duration, isNull);
    expect(review(start: 2000, end: 1000).duration, isNull);
  });

  SurgeryRecord record({
    String? videoPath,
    String? videoDisplayName,
    String caseMemo = '',
  }) {
    return SurgeryRecord(
      id: 'record',
      surgeryDate: DateTime(2026, 7, 15),
      eyeSide: EyeSide.right,
      reviewStatus: ReviewStatus.draft,
      videoPath: videoPath,
      videoDisplayName: videoDisplayName,
      caseMemo: caseMemo,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  test('動画情報と症例メモの初期値はnullまたは空文字', () {
    final item = record();
    expect(item.videoPath, isNull);
    expect(item.videoDisplayName, isNull);
    expect(item.caseMemo, '');
  });

  test('copyWithで動画情報と症例メモを更新できる', () {
    final updated = record().copyWith(
      videoPath: 'videos/record/abc.mp4',
      videoDisplayName: 'surgery.mp4',
      caseMemo: '通常通り。',
    );

    expect(updated.videoPath, 'videos/record/abc.mp4');
    expect(updated.videoDisplayName, 'surgery.mp4');
    expect(updated.caseMemo, '通常通り。');
  });

  test('clearVideoで動画情報のみクリアされ症例メモは維持される', () {
    final withVideo = record(
      videoPath: 'videos/record/abc.mp4',
      videoDisplayName: 'surgery.mp4',
      caseMemo: '通常通り。',
    );

    final cleared = withVideo.copyWith(clearVideo: true);

    expect(cleared.videoPath, isNull);
    expect(cleared.videoDisplayName, isNull);
    expect(cleared.caseMemo, '通常通り。');
  });
}
