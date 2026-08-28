import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/procedure_timing_rules.dart';
import '../domain/surgery_models.dart';
import '../domain/surgery_review_rules.dart';
import '../domain/surgery_trend.dart';
import 'app_database.dart';
import 'record_mutation_coordinator.dart';

const _surgeryDayOrderExpression = '''
COALESCE(
  surgery_day,
  CAST(
    strftime('%Y%m%d', surgery_date / 1000.0, 'unixepoch', 'localtime')
    AS INTEGER
  )
)
''';

const _aliasedSurgeryDayOrderExpression = '''
COALESCE(
  r.surgery_day,
  CAST(
    strftime('%Y%m%d', r.surgery_date / 1000.0, 'unixepoch', 'localtime')
    AS INTEGER
  )
)
''';

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

final class VideoDurationConflictException implements Exception {
  const VideoDurationConflictException({
    required this.destinationDurationMilliseconds,
    required this.maximumTimingMilliseconds,
    required this.hasInvalidTiming,
  });

  final int destinationDurationMilliseconds;
  final int maximumTimingMilliseconds;
  final bool hasInvalidTiming;

  @override
  String toString() => '動画の長さが、保存済みの工程時刻を満たしていません。';
}

final class VideoTimelineIdentityConflictException implements Exception {
  const VideoTimelineIdentityConflictException();

  @override
  String toString() => '工程時刻が追加されたため、動画の同一性を再確認する必要があります。';
}

final class _VideoTimingBounds {
  const _VideoTimingBounds({
    required this.maximumMilliseconds,
    required this.hasInvalidTiming,
    required this.hasRecordedTiming,
  });

  final int maximumMilliseconds;
  final bool hasInvalidTiming;
  final bool hasRecordedTiming;

  bool exceeds(int durationMilliseconds) =>
      hasInvalidTiming || maximumMilliseconds > durationMilliseconds;
}

class SurgeryRecordProgress {
  const SurgeryRecordProgress({
    required this.record,
    required this.completedStepCount,
    required this.hasRunningStep,
    required this.totalSurgeryDuration,
    this.timingReviewStatus,
  });

  final SurgeryRecord record;
  final int completedStepCount;
  final bool hasRunningStep;
  final Duration? totalSurgeryDuration;
  final CaseTimingReviewStatus? timingReviewStatus;
}

/// Existing procedure-timing rows for one record, read without backfilling.
///
/// Missing rows deliberately remain absent so read-only screens can render
/// them as unregistered without changing the database.
final class RecordProcedureTimingSnapshot {
  RecordProcedureTimingSnapshot({
    required this.surgeryRecordId,
    required Map<SurgicalStep, SurgicalStepReview> reviewsByStep,
  }) : reviewsByStep = Map.unmodifiable(reviewsByStep);

  final String surgeryRecordId;
  final Map<SurgicalStep, SurgicalStepReview> reviewsByStep;

  SurgicalStepReview? reviewFor(SurgicalStep step) => reviewsByStep[step];
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
  final SurgeryReviewRules _reviewRules = const SurgeryReviewRules();

  String allocateRecordId() => _uuid.v4();

  Future<bool> hasAnyRecords() async {
    final row = await _database.customSelect('''
SELECT EXISTS(
  SELECT 1
  FROM surgery_records
  LIMIT 1
) AS has_records
''', readsFrom: const {}).getSingle();
    return row.read<int>('has_records') != 0;
  }

  Future<T> runRecordMutation<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return _mutationCoordinator.run(surgeryRecordId, action);
  }

  /// Runs a consistency-sensitive operation while serializing application
  /// mutations for this record and holding one database transaction.
  ///
  /// Direct video jumps use this for the final record/step validation and the
  /// one-time seek handoff, so a timing edit, deletion, or video replacement
  /// cannot interleave between the validation reads and the request.
  Future<T> runRecordTransaction<T>(
    String surgeryRecordId,
    Future<T> Function() action,
  ) {
    return runRecordMutation(
      surgeryRecordId,
      () => _database.transaction(action),
    );
  }

  Future<List<SurgeryRecord>> watchableListSnapshot() async {
    final rows = await _database.customSelect('''
SELECT * FROM surgery_records
ORDER BY $_surgeryDayOrderExpression DESC, created_at DESC, id ASC
''', readsFrom: const {}).get();
    return rows.map(_recordFromRow).toList();
  }

  Stream<List<SurgeryRecord>> watchRecords() {
    return _database
        .customSelect('''
SELECT * FROM surgery_records
ORDER BY $_surgeryDayOrderExpression DESC, created_at DESC, id ASC
''', readsFrom: const {})
        .watch()
        .map((rows) => rows.map(_recordFromRow).toList());
  }

  /// Returns list/detail supporting information without creating review rows.
  Future<List<SurgeryRecordProgress>> fetchRecordProgressSnapshots() async {
    final displayStepIds = activeIndividualSurgicalSteps
        .map((step) => "'${step.storageId}'")
        .join(', ');
    final rows = await _database.customSelect('''
SELECT
  r.*,
  SUM(CASE
    WHEN s.step IN ($displayStepIds)
      AND (
        (s.start_milliseconds IS NOT NULL
          AND s.end_milliseconds IS NOT NULL
          AND s.end_milliseconds > s.start_milliseconds)
        OR (
          s.start_milliseconds IS NULL
          AND s.end_milliseconds IS NULL
          AND s.is_skipped = 1
        )
      )
    THEN 1 ELSE 0 END) AS completed_step_count,
  MAX(CASE
    WHEN s.step IN ($displayStepIds)
      AND s.start_milliseconds IS NOT NULL
      AND s.end_milliseconds IS NULL
    THEN 1 ELSE 0 END) AS has_running_step,
  MAX(CASE
    WHEN s.step IN ($displayStepIds)
      AND (
        s.start_milliseconds IS NOT NULL
        OR s.end_milliseconds IS NOT NULL
        OR s.is_skipped = 1
      )
    THEN 1 ELSE 0 END) AS has_individual_step_input,
  MAX(CASE
    WHEN s.step = '${SurgicalStep.totalSurgeryTime.storageId}'
      AND (
        s.start_milliseconds IS NOT NULL
        OR s.end_milliseconds IS NOT NULL
      )
    THEN 1 ELSE 0 END) AS has_total_surgery_timing_input,
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
ORDER BY $_aliasedSurgeryDayOrderExpression DESC,
  r.created_at DESC,
  r.id ASC
''', readsFrom: const {}).get();
    return rows
        .map((row) {
          final totalMilliseconds = row.read<int?>('total_surgery_duration');
          final totalSurgeryDuration = totalMilliseconds == null
              ? null
              : Duration(milliseconds: totalMilliseconds);
          return SurgeryRecordProgress(
            record: _recordFromRow(row),
            completedStepCount: row.read<int>('completed_step_count'),
            hasRunningStep: row.read<int>('has_running_step') == 1,
            totalSurgeryDuration: totalSurgeryDuration,
            timingReviewStatus: _reviewRules.calculateCaseStatus(
              reviewSchemaVersion: row.read<int?>('review_schema_version'),
              totalSurgeryDuration: totalSurgeryDuration,
              hasTotalSurgeryTimingInput:
                  row.read<int>('has_total_surgery_timing_input') == 1,
              processedStepCount: row.read<int>('completed_step_count'),
              hasIndividualStepInput:
                  row.read<int>('has_individual_step_input') == 1,
            ),
          );
        })
        .toList(growable: false);
  }

  /// Reads the total-surgery row and existing active-step rows in one result.
  ///
  /// Unlike [ensureStepReviews], this method never inserts missing rows. The
  /// storage-ID filter also prevents unknown and hidden legacy rows from being
  /// decoded or modified merely because a detail screen is displayed.
  Future<RecordProcedureTimingSnapshot> fetchRecordProcedureTimingSnapshot(
    String surgeryRecordId,
  ) async {
    final includedSteps = <SurgicalStep>[
      SurgicalStep.totalSurgeryTime,
      ...activeIndividualSurgicalSteps,
    ];
    final placeholders = List.filled(includedSteps.length, '?').join(', ');
    final rows = await _database
        .customSelect(
          '''
SELECT * FROM surgical_step_reviews
WHERE surgery_record_id = ?
  AND step IN ($placeholders)
''',
          variables: <Variable<Object>>[
            Variable<String>(surgeryRecordId),
            for (final step in includedSteps) Variable<String>(step.storageId),
          ],
          readsFrom: const {},
        )
        .get();

    final reviewsByStep = <SurgicalStep, SurgicalStepReview>{};
    for (final row in rows) {
      final review = _reviewFromRow(row);
      if (reviewsByStep.containsKey(review.step)) {
        throw StateError('同じ工程の記録が重複しています。');
      }
      reviewsByStep[review.step] = review;
    }
    return RecordProcedureTimingSnapshot(
      surgeryRecordId: surgeryRecordId,
      reviewsByStep: reviewsByStep,
    );
  }

  /// Reads only the metadata and timing values needed by the analysis screen.
  /// This method never creates missing step reviews or touches video files.
  Future<SurgeryAnalysisSnapshot> fetchAnalysisSnapshot() async {
    final rows = await _database.customSelect('''
SELECT
  r.id AS record_id,
  r.surgery_date,
  r.surgery_day,
  r.created_at,
  r.eye_side,
  s.step,
  s.start_milliseconds,
  s.end_milliseconds,
  s.is_skipped
FROM surgery_records AS r
LEFT JOIN surgical_step_reviews AS s
  ON s.surgery_record_id = r.id
ORDER BY $_aliasedSurgeryDayOrderExpression ASC,
  r.created_at ASC,
  r.id COLLATE BINARY ASC
''', readsFrom: const {}).get();

    final catalogById = <String, SurgeryAnalysisRecord>{};
    final measurementKeys = <(String, String)>{};
    final measurements = <SurgeryAnalysisMeasurement>[];
    for (final row in rows) {
      final recordId = row.read<String>('record_id');
      if (recordId.isEmpty) {
        throw const FormatException('分析SnapshotのrecordIdが空です。');
      }
      final surgeryDate = _surgeryDateFromRow(row);
      final createdAt = _millisToDate(row.read<int>('created_at'));
      final rawEyeSide = row.read<String>('eye_side');
      final eyeSide = EyeSide.values
          .where((value) => value.name == rawEyeSide)
          .firstOrNull;
      final existingRecord = catalogById[recordId];
      if (existingRecord == null) {
        catalogById[recordId] = SurgeryAnalysisRecord(
          recordId: recordId,
          surgeryDate: surgeryDate,
          createdAt: createdAt,
          rawEyeSide: rawEyeSide,
          eyeSide: eyeSide,
          caseOrdinal: 0,
        );
      } else if (existingRecord.surgeryDate != surgeryDate ||
          existingRecord.createdAt != createdAt ||
          existingRecord.rawEyeSide != rawEyeSide) {
        throw FormatException('分析Snapshot内で症例metadataが競合しています: $recordId');
      }

      final storageId = row.read<String?>('step');
      if (storageId == null) {
        continue;
      }
      if (!measurementKeys.add((recordId, storageId))) {
        throw FormatException('分析Snapshot内で工程measurementが重複しています: $recordId');
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
      final rawSkipped = row.read<int>('is_skipped');
      if (rawSkipped != 0 && rawSkipped != 1) {
        throw FormatException('分析Snapshotのskip状態が不正です: $recordId');
      }
      measurements.add(
        SurgeryAnalysisMeasurement(
          recordId: recordId,
          surgeryDate: surgeryDate,
          createdAt: createdAt,
          eyeSide: eyeSide,
          step: step,
          startMilliseconds: row.read<int?>('start_milliseconds'),
          endMilliseconds: row.read<int?>('end_milliseconds'),
          isSkipped: rawSkipped == 1,
        ),
      );
    }
    final unorderedCatalog = catalogById.values.toList();
    unorderedCatalog.sort((a, b) {
      final dateComparison = a.surgeryDay.compareTo(b.surgeryDay);
      if (dateComparison != 0) {
        return dateComparison;
      }
      final createdAtComparison = a.createdAt.compareTo(b.createdAt);
      if (createdAtComparison != 0) {
        return createdAtComparison;
      }
      return compareBinaryStrings(a.recordId, b.recordId);
    });
    final catalog = List<SurgeryAnalysisRecord>.unmodifiable([
      for (var index = 0; index < unorderedCatalog.length; index++)
        SurgeryAnalysisRecord(
          recordId: unorderedCatalog[index].recordId,
          surgeryDate: unorderedCatalog[index].surgeryDate,
          createdAt: unorderedCatalog[index].createdAt,
          rawEyeSide: unorderedCatalog[index].rawEyeSide,
          eyeSide: unorderedCatalog[index].eyeSide,
          caseOrdinal: index + 1,
        ),
    ]);
    final catalogIds = catalog.map((record) => record.recordId).toSet();
    if (catalogIds.length != catalog.length ||
        measurements.any(
          (measurement) => !catalogIds.contains(measurement.recordId),
        )) {
      throw const FormatException('分析Snapshotの参照整合性が壊れています。');
    }
    return SurgeryAnalysisSnapshot(
      recordCount: catalog.length,
      catalog: catalog,
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
    void Function()? ensureMutationAllowed,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      ensureMutationAllowed?.call();
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
        reviewSchemaVersion: 1,
        videoPath: videoPath,
        videoDisplayName: videoDisplayName,
        createdAt: now,
        updatedAt: now,
      );
      await _database.transaction(() async {
        ensureMutationAllowed?.call();
        await _database.customStatement(
          '''
INSERT INTO surgery_records (
  id, surgery_date, surgery_day, eye_side, review_status,
  review_schema_version, video_path, video_display_name,
  case_memo, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
          [
            record.id,
            _dateToMillis(record.surgeryDate),
            SurgeryDayCodec.encode(record.surgeryDate),
            record.eyeSide.name,
            record.reviewStatus.name,
            record.reviewSchemaVersion,
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

  /// Updates a video reference only when every latest persisted timing fits
  /// within the verified destination duration.
  ///
  /// The reference CAS, timing validation, and update share one database
  /// transaction. The timing predicate is repeated in the UPDATE so a timing
  /// write cannot slip between the validation read and the reference change.
  Future<void> updateVideoReferenceIfCurrentAndTimingsFit({
    required String surgeryRecordId,
    required String? expectedVideoPath,
    required String videoPath,
    required String videoDisplayName,
    required int destinationDurationMilliseconds,
    bool requireNoRecordedTimings = false,
    void Function()? ensureMutationAllowed,
  }) {
    if (destinationDurationMilliseconds <= 0) {
      throw ArgumentError.value(
        destinationDurationMilliseconds,
        'destinationDurationMilliseconds',
        '動画の長さは0ミリ秒より大きい必要があります。',
      );
    }
    return runRecordMutation(surgeryRecordId, () async {
      ensureMutationAllowed?.call();
      await _database.transaction(() async {
        await _assertExpectedVideoPath(
          surgeryRecordId: surgeryRecordId,
          expectedVideoPath: expectedVideoPath,
        );
        final timingBounds = await _readVideoTimingBounds(surgeryRecordId);
        if (requireNoRecordedTimings && timingBounds.hasRecordedTiming) {
          throw const VideoTimelineIdentityConflictException();
        }
        if (timingBounds.exceeds(destinationDurationMilliseconds)) {
          throw VideoDurationConflictException(
            destinationDurationMilliseconds: destinationDurationMilliseconds,
            maximumTimingMilliseconds: timingBounds.maximumMilliseconds,
            hasInvalidTiming: timingBounds.hasInvalidTiming,
          );
        }

        ensureMutationAllowed?.call();

        final affected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET video_path = ?, video_display_name = ?, updated_at = ?
WHERE id = ?
  AND ((video_path IS NULL AND ? IS NULL) OR video_path = ?)
  AND (? = 0 OR NOT EXISTS (
    SELECT 1
    FROM surgical_step_reviews
    WHERE surgery_record_id = ?
      AND (start_milliseconds IS NOT NULL OR end_milliseconds IS NOT NULL)
  ))
  AND NOT EXISTS (
    SELECT 1
    FROM surgical_step_reviews
    WHERE surgery_record_id = ?
      AND (
        (start_milliseconds IS NOT NULL AND (
          typeof(start_milliseconds) != 'integer'
          OR start_milliseconds < 0
          OR start_milliseconds > ?
        ))
        OR
        (end_milliseconds IS NOT NULL AND (
          typeof(end_milliseconds) != 'integer'
          OR end_milliseconds < 0
          OR end_milliseconds > ?
        ))
      )
  )
''',
          variables: <Variable<Object>>[
            Variable<String>(videoPath),
            Variable<String>(videoDisplayName),
            Variable<int>(_dateToMillis(DateTime.now())),
            Variable<String>(surgeryRecordId),
            Variable<String>(expectedVideoPath),
            Variable<String>(expectedVideoPath),
            Variable<int>(requireNoRecordedTimings ? 1 : 0),
            Variable<String>(surgeryRecordId),
            Variable<String>(surgeryRecordId),
            Variable<int>(destinationDurationMilliseconds),
            Variable<int>(destinationDurationMilliseconds),
          ],
        );
        if (affected == 1) {
          return;
        }

        final latest = await getRecord(surgeryRecordId);
        if (latest == null) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        if (latest.videoPath != expectedVideoPath) {
          throw VideoReferenceConflictException(
            expectedPath: expectedVideoPath,
            currentPath: latest.videoPath,
          );
        }
        final latestTimingBounds = await _readVideoTimingBounds(
          surgeryRecordId,
        );
        if (requireNoRecordedTimings && latestTimingBounds.hasRecordedTiming) {
          throw const VideoTimelineIdentityConflictException();
        }
        if (latestTimingBounds.exceeds(destinationDurationMilliseconds)) {
          throw VideoDurationConflictException(
            destinationDurationMilliseconds: destinationDurationMilliseconds,
            maximumTimingMilliseconds: latestTimingBounds.maximumMilliseconds,
            hasInvalidTiming: latestTimingBounds.hasInvalidTiming,
          );
        }
        throw StateError('動画参照を更新できませんでした。');
      });
    });
  }

  Future<void> replaceVideoReferenceAndClearTimings({
    required String surgeryRecordId,
    required String? expectedVideoPath,
    required String? videoPath,
    required String? videoDisplayName,
    void Function()? ensureMutationAllowed,
  }) {
    return runRecordMutation(surgeryRecordId, () async {
      ensureMutationAllowed?.call();
      await _database.transaction(() async {
        final updatedAt = _dateToMillis(DateTime.now());
        await _assertExpectedVideoPath(
          surgeryRecordId: surgeryRecordId,
          expectedVideoPath: expectedVideoPath,
        );
        ensureMutationAllowed?.call();
        final affected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET video_path = ?,
    video_display_name = ?,
    review_schema_version = 1,
    updated_at = ?
WHERE id = ?
  AND ((video_path IS NULL AND ? IS NULL) OR video_path = ?)
''',
          variables: <Variable<Object>>[
            Variable<String>(videoPath),
            Variable<String>(videoDisplayName),
            Variable<int>(updatedAt),
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
SET is_skipped = CASE
      WHEN start_milliseconds IS NULL
        AND end_milliseconds IS NULL
        AND is_skipped = 1
      THEN 1 ELSE 0
    END,
    start_milliseconds = NULL,
    end_milliseconds = NULL,
    updated_at = ?
WHERE surgery_record_id = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(updatedAt),
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
SET surgery_date = ?, surgery_day = ?, eye_side = ?, updated_at = ?
WHERE id = ?
''',
        variables: <Variable<Object>>[
          Variable<int>(_dateToMillis(normalizedDate)),
          Variable<int>(SurgeryDayCodec.encode(normalizedDate)),
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
      await _database.transaction(() async {
        final updatedAt = _dateToMillis(DateTime.now());
        final affected = await _database.customUpdate(
          '''
UPDATE surgical_step_reviews
SET is_skipped = CASE
      WHEN start_milliseconds IS NULL
        AND end_milliseconds IS NULL
        AND is_skipped = 1
      THEN 1 ELSE 0
    END,
    start_milliseconds = NULL,
    end_milliseconds = NULL,
    updated_at = ?
WHERE surgery_record_id = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(updatedAt),
            Variable<String>(surgeryRecordId),
          ],
        );
        final recordAffected = await _database.customUpdate(
          '''
UPDATE surgery_records
SET review_schema_version = 1, updated_at = ?
WHERE id = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(updatedAt),
            Variable<String>(surgeryRecordId),
          ],
        );
        if (recordAffected != 1) {
          throw SurgeryRecordNotFoundException(surgeryRecordId);
        }
        assert(affected >= 0);
      });
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

  /// Read-only timeline presence check used before deciding whether a selected
  /// video may keep existing positions. This never creates review rows.
  Future<bool> hasRecordedTimings(String surgeryRecordId) async {
    final rows = await _database
        .customSelect(
          '''
SELECT EXISTS(
  SELECT 1
  FROM surgical_step_reviews
  WHERE surgery_record_id = ?
    AND (start_milliseconds IS NOT NULL OR end_milliseconds IS NOT NULL)
) AS has_recorded_timings
''',
          variables: <Variable<Object>>[Variable<String>(surgeryRecordId)],
          readsFrom: const {},
        )
        .get();
    return rows.single.read<int>('has_recorded_timings') == 1;
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
SET start_milliseconds = ?,
    end_milliseconds = ?,
    is_skipped = 0,
    updated_at = ?
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
SET review_status = ?, review_schema_version = 1, updated_at = ?
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
          isSkipped: false,
          updatedAt: updatedAt,
        );
      });
    });
  }

  /// Persists the explicit "do not record timing" decision for one active
  /// individual step. This operation never requires a playable video, but it
  /// remains bound to the video reference observed by the caller.
  Future<SurgicalStepReview> saveStepSkipped({
    required SurgicalStepReview review,
    required bool isSkipped,
    required String? expectedVideoPath,
  }) {
    if (!activeIndividualSurgicalSteps.contains(review.step)) {
      throw ArgumentError('総手術時間または非表示工程は時間記録なしにできません。');
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
SET start_milliseconds = NULL,
    end_milliseconds = NULL,
    is_skipped = ?,
    updated_at = ?
WHERE id = ? AND surgery_record_id = ? AND step = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(isSkipped ? 1 : 0),
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
SET review_status = ?, review_schema_version = 1, updated_at = ?
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
        return existing.copyWith(
          clearStart: true,
          clearEnd: true,
          isSkipped: isSkipped,
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
      final updatedAt = _millisToDate(_dateToMillis(DateTime.now()));
      return _database.transaction(() async {
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
        final normalizedIsSkipped =
            review.startMilliseconds == null &&
            review.endMilliseconds == null &&
            review.isSkipped;
        final timingChanged =
            existing.startMilliseconds != review.startMilliseconds ||
            existing.endMilliseconds != review.endMilliseconds ||
            existing.isSkipped != normalizedIsSkipped;
        final affected = await _database.customUpdate(
          '''
UPDATE surgical_step_reviews
SET start_milliseconds = ?,
    end_milliseconds = ?,
    is_skipped = ?,
    rating = ?,
    reflection = ?,
    updated_at = ?
WHERE id = ? AND surgery_record_id = ? AND step = ?
''',
          variables: <Variable<Object>>[
            Variable<int>(review.startMilliseconds),
            Variable<int>(review.endMilliseconds),
            Variable<int>(normalizedIsSkipped ? 1 : 0),
            Variable<String>(review.rating.name),
            Variable<String>(review.reflection),
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
SET review_status = ?,
    review_schema_version = CASE
      WHEN ? = 1 THEN 1 ELSE review_schema_version
    END,
    updated_at = ?
WHERE id = ?
''',
          variables: <Variable<Object>>[
            Variable<String>(ReviewStatus.reviewed.name),
            Variable<int>(timingChanged ? 1 : 0),
            Variable<int>(_dateToMillis(updatedAt)),
            Variable<String>(review.surgeryRecordId),
          ],
        );
        if (recordAffected != 1) {
          throw SurgeryRecordNotFoundException(review.surgeryRecordId);
        }
        return existing.copyWith(
          startMilliseconds: review.startMilliseconds,
          endMilliseconds: review.endMilliseconds,
          clearStart: review.startMilliseconds == null,
          clearEnd: review.endMilliseconds == null,
          isSkipped: normalizedIsSkipped,
          rating: review.rating,
          reflection: review.reflection,
          updatedAt: updatedAt,
        );
      });
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

  Future<_VideoTimingBounds> _readVideoTimingBounds(
    String surgeryRecordId,
  ) async {
    final rows = await _database
        .customSelect(
          '''
SELECT
  COALESCE(MAX(
    CASE
      WHEN typeof(start_milliseconds) = 'integer'
        AND start_milliseconds >= 0
      THEN start_milliseconds
      ELSE 0
    END
  ), 0) AS maximum_start_milliseconds,
  COALESCE(MAX(
    CASE
      WHEN typeof(end_milliseconds) = 'integer'
        AND end_milliseconds >= 0
      THEN end_milliseconds
      ELSE 0
    END
  ), 0) AS maximum_end_milliseconds,
  COALESCE(MAX(
    CASE
      WHEN (start_milliseconds IS NOT NULL AND (
        typeof(start_milliseconds) != 'integer'
        OR start_milliseconds < 0
      ))
      OR (end_milliseconds IS NOT NULL AND (
        typeof(end_milliseconds) != 'integer'
        OR end_milliseconds < 0
      ))
      THEN 1 ELSE 0
    END
  ), 0) AS has_invalid_timing,
  COALESCE(MAX(
    CASE
      WHEN start_milliseconds IS NOT NULL
        OR end_milliseconds IS NOT NULL
      THEN 1 ELSE 0
    END
  ), 0) AS has_recorded_timing
FROM surgical_step_reviews
WHERE surgery_record_id = ?
''',
          variables: <Variable<Object>>[Variable<String>(surgeryRecordId)],
          readsFrom: const {},
        )
        .get();
    final row = rows.single;
    final maximumStart = row.read<int>('maximum_start_milliseconds');
    final maximumEnd = row.read<int>('maximum_end_milliseconds');
    return _VideoTimingBounds(
      maximumMilliseconds: maximumStart > maximumEnd
          ? maximumStart
          : maximumEnd,
      hasInvalidTiming: row.read<int>('has_invalid_timing') != 0,
      hasRecordedTiming: row.read<int>('has_recorded_timing') != 0,
    );
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
  is_skipped, rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
      <Object?>[
        _uuid.v4(),
        surgeryRecordId,
        step.storageId,
        null,
        null,
        0,
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
      surgeryDate: _surgeryDateFromRow(row),
      eyeSide: EyeSide.values.byName(row.read<String>('eye_side')),
      reviewStatus: ReviewStatus.values.byName(
        row.read<String>('review_status'),
      ),
      reviewSchemaVersion: row.read<int?>('review_schema_version'),
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
      isSkipped: row.read<int>('is_skipped') == 1,
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

  DateTime _surgeryDateFromRow(QueryRow row) {
    final encodedDay = row.read<int?>('surgery_day');
    return encodedDay == null
        ? _millisToDate(row.read<int>('surgery_date'))
        : SurgeryDayCodec.decode(encodedDay);
  }
}
