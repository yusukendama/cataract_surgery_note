import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
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
  });

  test('0秒の総時間は未設定として扱い工程完了数へ含めない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 15),
      eyeSide: EyeSide.left,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    await _setTiming(
      database,
      reviews
          .singleWhere((review) => review.step == SurgicalStep.totalSurgeryTime)
          .id,
      start: 900,
      end: 900,
    );

    final progress = (await repository.fetchRecordProgressSnapshots()).single;

    expect(progress.completedStepCount, 0);
    expect(progress.hasRunningStep, isFalse);
    expect(progress.totalSurgeryDuration, isNull);
  });
}

Future<void> _setTiming(
  AppDatabase database,
  String reviewId, {
  required int start,
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
