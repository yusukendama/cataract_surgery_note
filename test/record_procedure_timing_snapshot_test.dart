import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/domain/procedure_arrival_time.dart';
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

  test('既存の総手術行と対象工程行を同じread-only snapshotで返す', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final total = reviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    final nucleus = reviews.singleWhere(
      (review) => review.step == SurgicalStep.nucleusRemoval,
    );
    await _setTiming(database, total.id, start: 30000, end: 500000);
    await _setTiming(database, nucleus.id, start: 250000, end: 300000);

    final snapshot = await repository.fetchRecordProcedureTimingSnapshot(
      record.id,
    );

    expect(snapshot.surgeryRecordId, record.id);
    expect(snapshot.reviewsByStep, hasLength(11));
    expect(
      snapshot.reviewFor(SurgicalStep.totalSurgeryTime)?.startMilliseconds,
      30000,
    );
    expect(
      snapshot.reviewFor(SurgicalStep.nucleusRemoval)?.startMilliseconds,
      250000,
    );
  });

  test('skipフラグと有効時刻が併存する旧行を到着時刻と分析で別々に判定する', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    final reviews = await repository.ensureStepReviews(record.id);
    final total = reviews.singleWhere(
      (review) => review.step == SurgicalStep.totalSurgeryTime,
    );
    final capsulorhexis = reviews.singleWhere(
      (review) => review.step == SurgicalStep.capsulorhexis,
    );
    await _setTiming(database, total.id, start: 30000, end: 500000);
    await _setTiming(database, capsulorhexis.id, start: 250000, end: 300000);
    await database.customStatement(
      'UPDATE surgical_step_reviews SET is_skipped = 1 WHERE id = ?',
      <Object?>[capsulorhexis.id],
    );

    final procedureSnapshot = await repository
        .fetchRecordProcedureTimingSnapshot(record.id);
    final procedureReview = procedureSnapshot.reviewFor(
      SurgicalStep.capsulorhexis,
    );
    final arrivalTime = const ProcedureArrivalTimeCalculator().calculate(
      step: SurgicalStep.capsulorhexis,
      stepReview: procedureReview,
      totalSurgeryReview: procedureSnapshot.reviewFor(
        SurgicalStep.totalSurgeryTime,
      ),
    );
    final analysisSnapshot = await repository.fetchAnalysisSnapshot();
    final analysisMeasurement = analysisSnapshot.measurements.singleWhere(
      (measurement) => measurement.step == SurgicalStep.capsulorhexis,
    );

    expect(procedureReview?.isSkipped, isTrue);
    expect(procedureReview?.recordingStatus, StepRecordingStatus.recorded);
    expect(arrivalTime.status, ProcedureArrivalTimeStatus.available);
    expect(arrivalTime.duration, const Duration(minutes: 3, seconds: 40));
    expect(analysisSnapshot.recordCount, 1);
    expect(analysisSnapshot.catalog.single.recordId, record.id);
    expect(analysisMeasurement.isSkipped, isTrue);
    expect(analysisMeasurement.duration, isNull);
  });

  test('不足工程と総手術行を読み取り時に作成しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.left,
    );
    final before = await _tableSnapshot(database);

    final snapshot = await repository.fetchRecordProcedureTimingSnapshot(
      record.id,
    );
    final after = await _tableSnapshot(database);

    expect(snapshot.reviewsByStep.keys, [SurgicalStep.capsulorhexis]);
    expect(snapshot.reviewFor(SurgicalStep.totalSurgeryTime), isNull);
    expect(snapshot.reviewFor(SurgicalStep.nucleusRemoval), isNull);
    expect(after, before);
  });

  test('total行なしで開始済み工程があってもtotal行を補完しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    final ccc = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await _setTiming(database, ccc!.id, start: 250000, end: 300000);
    final countBefore = await _rowCount(database, record.id);

    final snapshot = await repository.fetchRecordProcedureTimingSnapshot(
      record.id,
    );

    expect(snapshot.reviewFor(SurgicalStep.totalSurgeryTime), isNull);
    expect(
      snapshot.reviewFor(SurgicalStep.capsulorhexis)?.startMilliseconds,
      250000,
    );
    expect(await _rowCount(database, record.id), countBefore);
  });

  test('未知工程と非表示legacy工程を読み飛ばして一切変更しない', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    await repository.ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.subTenonAnesthesia,
    );
    await _insertUnknownReview(
      database,
      record.id,
      id: 'unknown-review',
      startValue: 'not-an-integer',
      rating: 'future-rating',
    );
    final before = await _tableSnapshot(database);

    final snapshot = await repository.fetchRecordProcedureTimingSnapshot(
      record.id,
    );
    final after = await _tableSnapshot(database);

    expect(snapshot.reviewsByStep.keys, [SurgicalStep.capsulorhexis]);
    expect(
      snapshot.reviewsByStep,
      isNot(contains(SurgicalStep.subTenonAnesthesia)),
    );
    expect(after, before);
  });

  test('対象症例以外の工程行を混入させない', () async {
    final first = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    final second = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 21),
      eyeSide: EyeSide.left,
    );
    final firstTotal = await repository.ensureStepReview(
      surgeryRecordId: first.id,
      step: SurgicalStep.totalSurgeryTime,
    );
    final secondTotal = await repository.ensureStepReview(
      surgeryRecordId: second.id,
      step: SurgicalStep.totalSurgeryTime,
    );
    await _setTiming(database, firstTotal.id, start: 1000, end: 3000);
    await _setTiming(database, secondTotal.id, start: 9000, end: 12000);

    final snapshot = await repository.fetchRecordProcedureTimingSnapshot(
      first.id,
    );

    expect(
      snapshot.reviewFor(SurgicalStep.totalSurgeryTime)?.surgeryRecordId,
      first.id,
    );
    expect(
      snapshot.reviewFor(SurgicalStep.totalSurgeryTime)?.startMilliseconds,
      1000,
    );
    expect(
      snapshot.reviewsByStep.values.every(
        (review) => review.surgeryRecordId == first.id,
      ),
      isTrue,
    );
  });

  test('既知工程の型不整合を空snapshotへ変換せず失敗させる', () async {
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 20),
      eyeSide: EyeSide.right,
    );
    final ccc = await repository.getStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    await database.customStatement(
      'UPDATE surgical_step_reviews SET start_milliseconds = ? WHERE id = ?',
      <Object?>['not-an-integer', ccc!.id],
    );

    await expectLater(
      repository.fetchRecordProcedureTimingSnapshot(record.id),
      throwsA(anything),
    );
    expect(await _rowCount(database, record.id), 1);
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

Future<void> _insertUnknownReview(
  AppDatabase database,
  String recordId, {
  required String id,
  required Object? startValue,
  required String rating,
}) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;
  return database.customStatement(
    '''
INSERT INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  is_skipped, rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
    <Object?>[
      id,
      recordId,
      'unknown_future_step',
      startValue,
      2000,
      0,
      rating,
      '',
      now,
      now,
    ],
  );
}

Future<int> _rowCount(AppDatabase database, String recordId) async {
  final row = await database
      .customSelect(
        '''
SELECT COUNT(*) AS count
FROM surgical_step_reviews
WHERE surgery_record_id = ?
''',
        variables: <Variable<Object>>[Variable<String>(recordId)],
      )
      .getSingle();
  return row.read<int>('count');
}

Future<List<Map<String, Object?>>> _tableSnapshot(AppDatabase database) async {
  final rows = await database
      .customSelect('SELECT * FROM surgical_step_reviews ORDER BY id')
      .get();
  return [for (final row in rows) Map<String, Object?>.from(row.data)];
}
