import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../domain/procedure_timing_rules.dart';
import '../domain/surgery_models.dart';
import 'app_database.dart';

class SurgeryRepository {
  SurgeryRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;
  final ProcedureTimingRules _rules = const ProcedureTimingRules();

  Future<List<SurgeryRecord>> watchableListSnapshot() async {
    final rows = await _database.customSelect('''
SELECT * FROM surgery_records
ORDER BY surgery_date DESC, created_at DESC
''', readsFrom: const {}).get();
    return rows.map(_recordFromRow).toList();
  }

  Stream<List<SurgeryRecord>> watchRecords() {
    return _database
        .customSelect('''
SELECT * FROM surgery_records
ORDER BY surgery_date DESC, created_at DESC
''', readsFrom: const {})
        .watch()
        .map((rows) => rows.map(_recordFromRow).toList());
  }

  Future<SurgeryRecord?> getRecord(String id) async {
    final rows = await _database
        .customSelect(
          'SELECT * FROM surgery_records WHERE id = ? LIMIT 1',
          variables: [Variable<String>(id)],
          readsFrom: const {},
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _recordFromRow(rows.single);
  }

  Future<SurgeryRecord> createRecord({
    required DateTime surgeryDate,
    required EyeSide eyeSide,
  }) async {
    final now = DateTime.now();
    final record = SurgeryRecord(
      id: _uuid.v4(),
      surgeryDate: DateTime(
        surgeryDate.year,
        surgeryDate.month,
        surgeryDate.day,
      ),
      eyeSide: eyeSide,
      reviewStatus: ReviewStatus.draft,
      createdAt: now,
      updatedAt: now,
    );
    await _database.customStatement(
      '''
INSERT INTO surgery_records (
  id, surgery_date, eye_side, review_status,
  video_path, video_display_name, case_memo, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        record.id,
        _dateToMillis(record.surgeryDate),
        record.eyeSide.name,
        record.reviewStatus.name,
        record.videoPath,
        record.videoDisplayName,
        record.caseMemo,
        _dateToMillis(record.createdAt),
        _dateToMillis(record.updatedAt),
      ],
    );
    await ensureStepReview(
      surgeryRecordId: record.id,
      step: SurgicalStep.capsulorhexis,
    );
    return record;
  }

  Future<void> deleteRecord(String surgeryRecordId) async {
    await _database.customStatement(
      'DELETE FROM surgery_records WHERE id = ?',
      [surgeryRecordId],
    );
  }

  Future<void> updateVideoReference({
    required String surgeryRecordId,
    required String? videoPath,
    required String? videoDisplayName,
  }) async {
    await _database.customStatement(
      '''
UPDATE surgery_records
SET video_path = ?, video_display_name = ?, updated_at = ?
WHERE id = ?
''',
      [
        videoPath,
        videoDisplayName,
        _dateToMillis(DateTime.now()),
        surgeryRecordId,
      ],
    );
  }

  Future<void> updateCaseMemo({
    required String surgeryRecordId,
    required String caseMemo,
  }) async {
    await _database.customStatement(
      '''
UPDATE surgery_records
SET case_memo = ?, updated_at = ?
WHERE id = ?
''',
      [caseMemo, _dateToMillis(DateTime.now()), surgeryRecordId],
    );
  }

  /// Clears start/end timing for every step of a record, e.g. because the
  /// registered video was replaced or removed. Ratings and reflections are
  /// intentionally preserved.
  Future<void> clearStepTimings(String surgeryRecordId) async {
    await _database.customStatement(
      '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL, end_milliseconds = NULL, updated_at = ?
WHERE surgery_record_id = ?
''',
      [_dateToMillis(DateTime.now()), surgeryRecordId],
    );
  }

  Future<SurgicalStepReview> ensureStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final existing = await getStepReview(
      surgeryRecordId: surgeryRecordId,
      step: step,
    );
    if (existing != null) {
      return existing;
    }
    final now = DateTime.now();
    final review = SurgicalStepReview(
      id: _uuid.v4(),
      surgeryRecordId: surgeryRecordId,
      step: step,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: now,
      updatedAt: now,
    );
    await _database.customStatement(
      '''
INSERT INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        review.id,
        review.surgeryRecordId,
        review.step.storageId,
        review.startMilliseconds,
        review.endMilliseconds,
        review.rating.name,
        review.reflection,
        _dateToMillis(review.createdAt),
        _dateToMillis(review.updatedAt),
      ],
    );
    return review;
  }

  Future<SurgicalStepReview?> getStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) async {
    final rows = await _database
        .customSelect(
          '''
SELECT * FROM surgical_step_reviews
WHERE surgery_record_id = ? AND step = ?
LIMIT 1
''',
          variables: [
            Variable<String>(surgeryRecordId),
            Variable<String>(step.storageId),
          ],
          readsFrom: const {},
        )
        .get();
    if (rows.isEmpty) {
      return null;
    }
    return _reviewFromRow(rows.single);
  }

  Future<List<SurgicalStepReview>> ensureStepReviews(
    String surgeryRecordId,
  ) async {
    final reviews = <SurgicalStepReview>[];
    for (final step in surgicalStepsInDisplayOrder) {
      reviews.add(
        await ensureStepReview(surgeryRecordId: surgeryRecordId, step: step),
      );
    }
    return reviews;
  }

  Future<SurgicalStepReview> saveStepReview(SurgicalStepReview review) async {
    final validation = _rules.validateRange(
      startMilliseconds: review.startMilliseconds,
      endMilliseconds: review.endMilliseconds,
    );
    if (validation != null) {
      throw ArgumentError(validation);
    }

    final updated = review.copyWith(updatedAt: DateTime.now());
    await _database.transaction(() async {
      await _database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?,
    end_milliseconds = ?,
    rating = ?,
    reflection = ?,
    updated_at = ?
WHERE id = ?
''',
        [
          updated.startMilliseconds,
          updated.endMilliseconds,
          updated.rating.name,
          updated.reflection,
          _dateToMillis(updated.updatedAt),
          updated.id,
        ],
      );
      await _database.customStatement(
        '''
UPDATE surgery_records
SET review_status = ?, updated_at = ?
WHERE id = ?
''',
        [
          ReviewStatus.reviewed.name,
          _dateToMillis(DateTime.now()),
          updated.surgeryRecordId,
        ],
      );
    });
    return updated;
  }

  Future<void> close() => _database.close();

  SurgeryRecord _recordFromRow(QueryRow row) {
    return SurgeryRecord(
      id: row.read<String>('id'),
      surgeryDate: _millisToDate(row.read<int>('surgery_date')),
      eyeSide: EyeSide.values.byName(row.read<String>('eye_side')),
      reviewStatus: ReviewStatus.values.byName(
        row.read<String>('review_status'),
      ),
      videoPath: row.read<String?>('video_path'),
      videoDisplayName: row.read<String?>('video_display_name'),
      caseMemo: row.read<String?>('case_memo') ?? '',
      createdAt: _millisToDate(row.read<int>('created_at')),
      updatedAt: _millisToDate(row.read<int>('updated_at')),
    );
  }

  SurgicalStepReview _reviewFromRow(QueryRow row) {
    return SurgicalStepReview(
      id: row.read<String>('id'),
      surgeryRecordId: row.read<String>('surgery_record_id'),
      step: SurgicalStep.fromStorageId(row.read<String>('step'))!,
      startMilliseconds: row.read<int?>('start_milliseconds'),
      endMilliseconds: row.read<int?>('end_milliseconds'),
      rating: StepRating.values.byName(row.read<String>('rating')),
      reflection: row.read<String>('reflection'),
      createdAt: _millisToDate(row.read<int>('created_at')),
      updatedAt: _millisToDate(row.read<int>('updated_at')),
    );
  }

  int _dateToMillis(DateTime dateTime) =>
      dateTime.toUtc().millisecondsSinceEpoch;

  DateTime _millisToDate(int milliseconds) {
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
      isUtc: true,
    ).toLocal();
  }
}
