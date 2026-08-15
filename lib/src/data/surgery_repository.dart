import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/procedure_timing_rules.dart';
import '../domain/surgery_models.dart';
import '../domain/surgery_trend.dart';
import 'app_database.dart';
import 'record_mutation_coordinator.dart';

class ReviewSaveResult {
  const ReviewSaveResult({required this.record, required this.reviews});

  final SurgeryRecord record;
  final List<SurgicalStepReview> reviews;
}

class DeletedRecordCleanupToken {
  const DeletedRecordCleanupToken({
    required this.recordId,
    required this.previousVideoPath,
  });

  final String recordId;
  final String? previousVideoPath;
}

class SurgeryVideoReferenceRow {
  const SurgeryVideoReferenceRow({
    required this.recordId,
    required this.videoPath,
  });

  final String recordId;
  final String? videoPath;
}

class SurgeryRecordProgress {
  const SurgeryRecordProgress({
    required this.record,
    required this.completedStepCount,
    required this.hasRunningStep,
    required this.totalSurgeryDuration,
  });

  final SurgeryRecord record;
  final int completedStepCount;
  final bool hasRunningStep;
  final Duration? totalSurgeryDuration;
}

class SurgeryRepository {
  SurgeryRepository(
    this._database, {
    Uuid? uuid,
    RecordMutationCoordinator? mutationCoordinator,
  }) : _uuid = uuid ?? const Uuid(),
       _mutationCoordinator =
           mutationCoordinator ?? RecordMutationCoordinator();

  final AppDatabase _database;
  final Uuid _uuid;
  final RecordMutationCoordinator _mutationCoordinator;
  final ProcedureTimingRules _rules = const ProcedureTimingRules();

  String allocateRecordId() => _uuid.v4();

  Future<T> runRecordMutation<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return _mutationCoordinator.run(surgeryRecordId, action);
  }

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

  /// Returns list/detail supporting information without creating review rows.
  Future<List<SurgeryRecordProgress>> fetchRecordProgressSnapshots() async {
    final displayStepIds = surgicalStepsInDisplayOrder
        .where((step) => !step.isTotalSurgeryTime)
        .map((step) => "'${step.storageId}'")
        .join(', ');
    final rows = await _database.customSelect('''
SELECT
  r.*,
  SUM(CASE
    WHEN s.step IN ($displayStepIds)
      AND s.start_milliseconds IS NOT NULL
      AND s.end_milliseconds IS NOT NULL
      AND s.end_milliseconds > s.start_milliseconds
    THEN 1 ELSE 0 END) AS completed_step_count,
  MAX(CASE
    WHEN s.step IN ($displayStepIds)
      AND s.start_milliseconds IS NOT NULL
      AND s.end_milliseconds IS NULL
    THEN 1 ELSE 0 END) AS has_running_step,
  MAX(CASE
    WHEN s.step = '${SurgicalStep.totalSurgeryTime.storageId}'
      AND s.start_milliseconds IS NOT NULL
      AND s.end_milliseconds IS NOT NULL
      AND s.end_milliseconds > s.start_milliseconds
    THEN s.end_milliseconds - s.start_milliseconds ELSE NULL END)
    AS total_surgery_duration
FROM surgery_records AS r
LEFT JOIN surgical_step_reviews AS s
  ON s.surgery_record_id = r.id
GROUP BY r.id
ORDER BY r.surgery_date DESC, r.created_at DESC
''', readsFrom: const {}).get();
    return rows
        .map((row) {
          final totalMilliseconds = row.read<int?>('total_surgery_duration');
          return SurgeryRecordProgress(
            record: _recordFromRow(row),
            completedStepCount: row.read<int>('completed_step_count'),
            hasRunningStep: row.read<int>('has_running_step') == 1,
            totalSurgeryDuration: totalMilliseconds == null
                ? null
                : Duration(milliseconds: totalMilliseconds),
          );
        })
        .toList(growable: false);
  }

  /// Reads only the metadata and timing values needed by the analysis screen.
  /// This method never creates missing step reviews or touches video files.
  Future<SurgeryAnalysisSnapshot> fetchAnalysisSnapshot() async {
    final rows = await _database.customSelect('''
SELECT
  r.id AS record_id,
  r.surgery_date,
  r.created_at,
  r.eye_side,
  s.step,
  s.start_milliseconds,
  s.end_milliseconds
FROM surgery_records AS r
LEFT JOIN surgical_step_reviews AS s
  ON s.surgery_record_id = r.id
ORDER BY r.surgery_date ASC, r.created_at ASC, r.id ASC
''', readsFrom: const {}).get();

    final recordIds = <String>{};
    final measurements = <SurgeryAnalysisMeasurement>[];
    for (final row in rows) {
      final recordId = row.read<String>('record_id');
      recordIds.add(recordId);
      final storageId = row.read<String?>('step');
      if (storageId == null) {
        continue;
      }
      final step = SurgicalStep.fromStorageId(storageId);
      if (step == null) {
        assert(() {
          debugPrint('分析対象外の未知の工程IDを除外しました: $storageId');
          return true;
        }());
        continue;
      }
      if (!surgicalStepsInDisplayOrder.contains(step)) {
        continue;
      }
      final eyeSideName = row.read<String>('eye_side');
      final eyeSide = EyeSide.values
          .where((value) => value.name == eyeSideName)
          .firstOrNull;
      if (eyeSide == null) {
        continue;
      }
      measurements.add(
        SurgeryAnalysisMeasurement(
          recordId: recordId,
          surgeryDate: _millisToDate(row.read<int>('surgery_date')),
          createdAt: _millisToDate(row.read<int>('created_at')),
          eyeSide: eyeSide,
          step: step,
          startMilliseconds: row.read<int?>('start_milliseconds'),
          endMilliseconds: row.read<int?>('end_milliseconds'),
        ),
      );
    }
    return SurgeryAnalysisSnapshot(
      recordCount: recordIds.length,
      measurements: List.unmodifiable(measurements),
    );
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
    return createRecordWithVideoReference(
      surgeryRecordId: allocateRecordId(),
      surgeryDate: surgeryDate,
      eyeSide: eyeSide,
      videoPath: null,
      videoDisplayName: null,
    );
  }

  /// Commits the record and the initial review row in one transaction.
  ///
  /// A caller that stages a video first must pass the preallocated ID and the
  /// staged managed reference here. No partially-created record is observable
  /// if any insert fails.
  Future<SurgeryRecord> createRecordWithVideoReference({
    required String surgeryRecordId,
    required DateTime surgeryDate,
    required EyeSide eyeSide,
    required String? videoPath,
    required String? videoDisplayName,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      final now = DateTime.now();
      final record = SurgeryRecord(
        id: surgeryRecordId,
        surgeryDate: DateTime(
          surgeryDate.year,
          surgeryDate.month,
          surgeryDate.day,
        ),
        eyeSide: eyeSide,
        reviewStatus: ReviewStatus.draft,
        videoPath: videoPath,
        videoDisplayName: videoDisplayName,
        createdAt: now,
        updatedAt: now,
      );
      await _database.transaction(() async {
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
        await _insertStepReviewIfMissing(
          surgeryRecordId: record.id,
          step: SurgicalStep.capsulorhexis,
          now: now,
        );
      });
      return record;
    });
  }

  Future<void> deleteRecord(String surgeryRecordId) async {
    await deleteRecordChecked(surgeryRecordId);
  }

  /// Deletes exactly one record and returns the only token that authorizes
  /// post-commit managed-directory cleanup.
  Future<DeletedRecordCleanupToken> deleteRecordChecked(
    String surgeryRecordId,
  ) {
    return runRecordMutation(surgeryRecordId, () async {
      return _database.transaction(() async {
        final record = await getRecord(surgeryRecordId);
        if (record == null) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        final affected = await _database.customUpdate(
          'DELETE FROM surgery_records WHERE id = ?',
          variables: <Variable<Object>>[Variable<String>(surgeryRecordId)],
        );
        if (affected != 1) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        return DeletedRecordCleanupToken(
          recordId: surgeryRecordId,
          previousVideoPath: record.videoPath,
        );
      });
    });
  }

  Future<void> updateVideoReference({
    required String surgeryRecordId,
    required String? videoPath,
    required String? videoDisplayName,
  }) async {
    final current = await getRecord(surgeryRecordId);
    if (current == null) {
      throw SurgeryRecordNotFoundException(surgeryRecordId);
    }
    await updateVideoReferenceIfCurrent(
      surgeryRecordId: surgeryRecordId,
      expectedVideoPath: current.videoPath,
      videoPath: videoPath,
      videoDisplayName: videoDisplayName,
    );
  }

  Future<void> updateVideoReferenceIfCurrent({
    required String surgeryRecordId,
    required String? expectedVideoPath,
    required String? videoPath,
    required String? videoDisplayName,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      await _database.transaction(() async {
        await _assertExpectedVideoPath(
          surgeryRecordId: surgeryRecordId,
          expectedVideoPath: expectedVideoPath,
        );
        final affected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET video_path = ?, video_display_name = ?, updated_at = ?
WHERE id = ?
  AND ((video_path IS NULL AND ? IS NULL) OR video_path = ?)
''',
          variables: <Variable<Object>>[
            Variable<String>(videoPath),
            Variable<String>(videoDisplayName),
            Variable<int>(_dateToMillis(DateTime.now())),
            Variable<String>(surgeryRecordId),
            Variable<String>(expectedVideoPath),
            Variable<String>(expectedVideoPath),
          ],
        );
        if (affected != 1) {
          final latest = await getRecord(surgeryRecordId);
          if (latest == null) {
            throw SurgeryRecordNotFoundException(surgeryRecordId);
          }
          throw VideoReferenceConflictException(
            expectedPath: expectedVideoPath,
            currentPath: latest.videoPath,
          );
        }
      });
    });
  }

  Future<void> replaceVideoReferenceAndClearTimings({
    required String surgeryRecordId,
    required String? expectedVideoPath,
    required String? videoPath,
    required String? videoDisplayName,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      await _database.transaction(() async {
        await _assertExpectedVideoPath(
          surgeryRecordId: surgeryRecordId,
          expectedVideoPath: expectedVideoPath,
        );
        final affected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET video_path = ?, video_display_name = ?, updated_at = ?
WHERE id = ?
  AND ((video_path IS NULL AND ? IS NULL) OR video_path = ?)
''',
          variables: <Variable<Object>>[
            Variable<String>(videoPath),
            Variable<String>(videoDisplayName),
            Variable<int>(_dateToMillis(DateTime.now())),
            Variable<String>(surgeryRecordId),
            Variable<String>(expectedVideoPath),
            Variable<String>(expectedVideoPath),
          ],
        );
        if (affected != 1) {
          final latest = await getRecord(surgeryRecordId);
          if (latest == null) {
            throw SurgeryRecordNotFoundException(surgeryRecordId);
          }
          throw VideoReferenceConflictException(
            expectedPath: expectedVideoPath,
            currentPath: latest.videoPath,
          );
        }
        await _database.customUpdate(
          '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL, end_milliseconds = NULL, updated_at = ?
WHERE surgery_record_id = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(_dateToMillis(DateTime.now())),
            Variable<String>(surgeryRecordId),
          ],
        );
      });
    });
  }

  Future<void> updateRecordDetails({
    required String surgeryRecordId,
    required DateTime surgeryDate,
    required EyeSide eyeSide,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      final normalizedDate = DateTime(
        surgeryDate.year,
        surgeryDate.month,
        surgeryDate.day,
      );
      final affected = await _database.customUpdate(
        '''
UPDATE surgery_records
SET surgery_date = ?, eye_side = ?, updated_at = ?
WHERE id = ?
''',
        variables: <Variable<Object>>[
          Variable<int>(_dateToMillis(normalizedDate)),
          Variable<String>(eyeSide.name),
          Variable<int>(_dateToMillis(DateTime.now())),
          Variable<String>(surgeryRecordId),
        ],
      );
      if (affected != 1) {
        throw SurgeryRecordNotFoundException(surgeryRecordId);
      }
    });
  }

  Future<void> updateCaseMemo({
    required String surgeryRecordId,
    required String caseMemo,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      final affected = await _database.customUpdate(
        '''
UPDATE surgery_records
SET case_memo = ?, updated_at = ?
WHERE id = ?
''',
        variables: <Variable<Object>>[
          Variable<String>(caseMemo),
          Variable<int>(_dateToMillis(DateTime.now())),
          Variable<String>(surgeryRecordId),
        ],
      );
      if (affected != 1) {
        throw SurgeryRecordNotFoundException(surgeryRecordId);
      }
    });
  }

  /// Clears start/end timing for every step of a record, e.g. because the
  /// registered video was replaced or removed. Ratings and reflections are
  /// intentionally preserved.
  Future<void> clearStepTimings(String surgeryRecordId) {
    return runRecordMutation(surgeryRecordId, () async {
      final record = await getRecord(surgeryRecordId);
      if (record == null) {
        throw SurgeryRecordNotFoundException(surgeryRecordId);
      }
      await _database.customStatement(
        '''
UPDATE surgical_step_reviews
SET start_milliseconds = NULL, end_milliseconds = NULL, updated_at = ?
WHERE surgery_record_id = ?
''',
        [_dateToMillis(DateTime.now()), surgeryRecordId],
      );
    });
  }

  Future<SurgicalStepReview> ensureStepReview({
    required String surgeryRecordId,
    required SurgicalStep step,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      return _database.transaction(() async {
        if (await getRecord(surgeryRecordId) == null) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        await _insertStepReviewIfMissing(
          surgeryRecordId: surgeryRecordId,
          step: step,
          now: DateTime.now(),
        );
        final review = await getStepReview(
          surgeryRecordId: surgeryRecordId,
          step: step,
        );
        if (review == null) {
          throw StateError('工程記録の補完に失敗しました。');
        }
        return review;
      });
    });
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

  Future<List<SurgicalStepReview>> ensureStepReviews(String surgeryRecordId) {
    return runRecordMutation(surgeryRecordId, () async {
      return _database.transaction(() async {
        if (await getRecord(surgeryRecordId) == null) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        final now = DateTime.now();
        for (final step in surgicalStepsInDisplayOrder) {
          await _insertStepReviewIfMissing(
            surgeryRecordId: surgeryRecordId,
            step: step,
            now: now,
          );
        }
        final reviews = <SurgicalStepReview>[];
        for (final step in surgicalStepsInDisplayOrder) {
          final review = await getStepReview(
            surgeryRecordId: surgeryRecordId,
            step: step,
          );
          if (review == null) {
            throw StateError('工程記録の補完に失敗しました。');
          }
          reviews.add(review);
        }
        return reviews;
      });
    });
  }

  /// Persists only the timeline fields of one step.
  ///
  /// [expectedVideoPath] binds the position to the video that was visible when
  /// the operation began. A replacement/removal therefore cannot be followed
  /// by a stale timing write.
  Future<SurgicalStepReview> saveStepTiming({
    required SurgicalStepReview review,
    required String? expectedVideoPath,
  }) {
    final validation = _rules.validateRange(
      startMilliseconds: review.startMilliseconds,
      endMilliseconds: review.endMilliseconds,
    );
    if (validation != null) {
      throw ArgumentError(validation);
    }

    return runRecordMutation(review.surgeryRecordId, () async {
      final updatedAt = _millisToDate(_dateToMillis(DateTime.now()));
      return _database.transaction(() async {
        await _assertExpectedVideoPath(
          surgeryRecordId: review.surgeryRecordId,
          expectedVideoPath: expectedVideoPath,
        );
        final existingRows = await _database
            .customSelect(
              '''
SELECT * FROM surgical_step_reviews
WHERE id = ? AND surgery_record_id = ? AND step = ?
LIMIT 1
''',
              variables: <Variable<Object>>[
                Variable<String>(review.id),
                Variable<String>(review.surgeryRecordId),
                Variable<String>(review.step.storageId),
              ],
              readsFrom: const {},
            )
            .get();
        if (existingRows.length != 1) {
          throw SurgicalStepReviewNotFoundException(review.id);
        }
        final existing = _reviewFromRow(existingRows.single);
        final affected = await _database.customUpdate(
          '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?, end_milliseconds = ?, updated_at = ?
WHERE id = ? AND surgery_record_id = ? AND step = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(review.startMilliseconds),
            Variable<int>(review.endMilliseconds),
            Variable<int>(_dateToMillis(updatedAt)),
            Variable<String>(review.id),
            Variable<String>(review.surgeryRecordId),
            Variable<String>(review.step.storageId),
          ],
        );
        if (affected != 1) {
          throw SurgicalStepReviewNotFoundException(review.id);
        }
        final recordAffected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET review_status = ?, updated_at = ?
WHERE id = ?
''',
          variables: <Variable<Object>>[
            Variable<String>(ReviewStatus.reviewed.name),
            Variable<int>(_dateToMillis(updatedAt)),
            Variable<String>(review.surgeryRecordId),
          ],
        );
        if (recordAffected != 1) {
          throw SurgeryRecordNotFoundException(review.surgeryRecordId);
        }
        // Build the exact committed value while still inside the transaction.
        // A read attempted after COMMIT can fail even though persistence has
        // already succeeded, and must never turn that success into a save
        // failure shown to the user.
        return existing.copyWith(
          startMilliseconds: review.startMilliseconds,
          endMilliseconds: review.endMilliseconds,
          clearStart: review.startMilliseconds == null,
          clearEnd: review.endMilliseconds == null,
          updatedAt: updatedAt,
        );
      });
    });
  }

  /// Atomically persists the editable review fields and the case memo.
  /// Timing columns are never included in these updates.
  Future<ReviewSaveResult> saveReviewContent({
    required String surgeryRecordId,
    required List<SurgicalStepReview> reviews,
    required String caseMemo,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      if (reviews.any((review) => review.surgeryRecordId != surgeryRecordId)) {
        throw ArgumentError('他の症例の工程記録は同時に保存できません。');
      }
      final ids = reviews.map((review) => review.id).toSet();
      if (ids.length != reviews.length) {
        throw ArgumentError('同じ工程記録が重複しています。');
      }

      final now = _millisToDate(_dateToMillis(DateTime.now()));
      return _database.transaction(() async {
        final record = await getRecord(surgeryRecordId);
        if (record == null) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        var reviewChanged = false;
        final committedReviews = <SurgicalStepReview>[];
        for (final review in reviews) {
          final rows = await _database
              .customSelect(
                '''
SELECT * FROM surgical_step_reviews
WHERE id = ? AND surgery_record_id = ?
LIMIT 1
''',
                variables: <Variable<Object>>[
                  Variable<String>(review.id),
                  Variable<String>(surgeryRecordId),
                ],
                readsFrom: const {},
              )
              .get();
          if (rows.length != 1) {
            throw SurgicalStepReviewNotFoundException(review.id);
          }
          final existing = _reviewFromRow(rows.single);
          if (existing.step != review.step) {
            throw SurgicalStepReviewNotFoundException(review.id);
          }
          reviewChanged =
              reviewChanged ||
              existing.rating != review.rating ||
              existing.reflection != review.reflection;

          final affected = await _database.customUpdate(
            '''
UPDATE surgical_step_reviews
SET rating = ?, reflection = ?, updated_at = ?
WHERE id = ? AND surgery_record_id = ?
''',
            variables: <Variable<Object>>[
              Variable<String>(review.rating.name),
              Variable<String>(review.reflection),
              Variable<int>(_dateToMillis(now)),
              Variable<String>(review.id),
              Variable<String>(surgeryRecordId),
            ],
          );
          if (affected != 1) {
            throw SurgicalStepReviewNotFoundException(review.id);
          }
          committedReviews.add(
            existing.copyWith(
              rating: review.rating,
              reflection: review.reflection,
              updatedAt: now,
            ),
          );
        }

        final affectedRecord = await _database.customUpdate(
          reviewChanged
              ? '''
UPDATE surgery_records
SET case_memo = ?, review_status = ?, updated_at = ?
WHERE id = ?
'''
              : '''
UPDATE surgery_records
SET case_memo = ?, updated_at = ?
WHERE id = ?
''',
          variables: reviewChanged
              ? <Variable<Object>>[
                  Variable<String>(caseMemo),
                  Variable<String>(ReviewStatus.reviewed.name),
                  Variable<int>(_dateToMillis(now)),
                  Variable<String>(surgeryRecordId),
                ]
              : <Variable<Object>>[
                  Variable<String>(caseMemo),
                  Variable<int>(_dateToMillis(now)),
                  Variable<String>(surgeryRecordId),
                ],
        );
        if (affectedRecord != 1) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        return ReviewSaveResult(
          record: record.copyWith(
            caseMemo: caseMemo,
            reviewStatus: reviewChanged
                ? ReviewStatus.reviewed
                : record.reviewStatus,
            updatedAt: now,
          ),
          reviews: List<SurgicalStepReview>.unmodifiable(committedReviews),
        );
      });
    });
  }

  /// Compatibility API for callers that have not yet separated timing and
  /// review drafts. New code must use [saveStepTiming] or [saveReviewContent].
  Future<SurgicalStepReview> saveStepReview(SurgicalStepReview review) {
    final validation = _rules.validateRange(
      startMilliseconds: review.startMilliseconds,
      endMilliseconds: review.endMilliseconds,
    );
    if (validation != null) {
      throw ArgumentError(validation);
    }

    return runRecordMutation(review.surgeryRecordId, () async {
      final updated = review.copyWith(updatedAt: DateTime.now());
      await _database.transaction(() async {
        final affected = await _database.customUpdate(
          '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?,
    end_milliseconds = ?,
    rating = ?,
    reflection = ?,
    updated_at = ?
WHERE id = ? AND surgery_record_id = ? AND step = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(updated.startMilliseconds),
            Variable<int>(updated.endMilliseconds),
            Variable<String>(updated.rating.name),
            Variable<String>(updated.reflection),
            Variable<int>(_dateToMillis(updated.updatedAt)),
            Variable<String>(updated.id),
            Variable<String>(updated.surgeryRecordId),
            Variable<String>(updated.step.storageId),
          ],
        );
        if (affected != 1) {
          throw SurgicalStepReviewNotFoundException(updated.id);
        }
        final recordAffected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET review_status = ?, updated_at = ?
WHERE id = ?
''',
          variables: <Variable<Object>>[
            Variable<String>(ReviewStatus.reviewed.name),
            Variable<int>(_dateToMillis(DateTime.now())),
            Variable<String>(updated.surgeryRecordId),
          ],
        );
        if (recordAffected != 1) {
          throw SurgeryRecordNotFoundException(updated.surgeryRecordId);
        }
      });
      return updated;
    });
  }

  Future<List<String?>> fetchAllVideoReferences() async {
    final rows = await fetchAllVideoReferencesWithIds();
    return List<String?>.unmodifiable(rows.map((row) => row.videoPath));
  }

  Future<List<SurgeryVideoReferenceRow>>
  fetchAllVideoReferencesWithIds() async {
    final rows = await _database
        .customSelect(
          'SELECT id, video_path FROM surgery_records',
          readsFrom: const {},
        )
        .get();
    return List<SurgeryVideoReferenceRow>.unmodifiable(
      rows.map(
        (row) => SurgeryVideoReferenceRow(
          recordId: row.read<String>('id'),
          videoPath: row.read<String?>('video_path'),
        ),
      ),
    );
  }

  Future<void> _assertExpectedVideoPath({
    required String surgeryRecordId,
    required String? expectedVideoPath,
  }) async {
    final record = await getRecord(surgeryRecordId);
    if (record == null) {
      throw SurgeryRecordNotFoundException(surgeryRecordId);
    }
    if (record.videoPath != expectedVideoPath) {
      throw VideoReferenceConflictException(
        expectedPath: expectedVideoPath,
        currentPath: record.videoPath,
      );
    }
  }

  Future<void> _insertStepReviewIfMissing({
    required String surgeryRecordId,
    required SurgicalStep step,
    required DateTime now,
  }) async {
    await _database.customStatement(
      '''
INSERT OR IGNORE INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        _uuid.v4(),
        surgeryRecordId,
        step.storageId,
        null,
        null,
        StepRating.unreviewed.name,
        '',
        _dateToMillis(now),
        _dateToMillis(now),
      ],
    );
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
