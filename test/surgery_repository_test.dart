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
}
