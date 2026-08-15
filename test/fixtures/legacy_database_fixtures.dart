import 'dart:io';

import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

const build1RightRecordId = 'build1-right-ccc';
const build1LeftRecordId = 'build1-left-started';
const build14ManagedRecordId = 'fixture-managed';
const build14LegacyRecordId = 'fixture-legacy';
const build14MissingRecordId = 'fixture-missing';

const build14LegacyVideoPath =
    '/private/tmp/cataract-surgery-note-fixture-legacy.mov';

/// Creates a real file-backed database with the schema used by the earliest
/// CCC-focused release. It deliberately predates video_path,
/// video_display_name and case_memo.
Future<void> createBuild1Fixture(File target) async {
  final database = _FixtureDatabase(target);
  try {
    await _createOldRecordsTable(database);
    await _createStepReviewsTable(database);
    await _insertRecord(
      database,
      id: build1RightRecordId,
      surgeryDate: 1704067200000,
      eyeSide: EyeSide.right,
      reviewStatus: ReviewStatus.reviewed,
      createdAt: 1704067201000,
      updatedAt: 1704067202000,
    );
    await _insertRecord(
      database,
      id: build1LeftRecordId,
      surgeryDate: 1704153600000,
      eyeSide: EyeSide.left,
      reviewStatus: ReviewStatus.draft,
      createdAt: 1704153601000,
      updatedAt: 1704153602000,
    );
    await _insertReview(
      database,
      id: 'build1-ccc-complete',
      recordId: build1RightRecordId,
      step: SurgicalStep.capsulorhexis.storageId,
      start: 1000,
      end: 5500,
      rating: StepRating.good,
      reflection: '円形を保てた。',
      createdAt: 1704067203000,
      updatedAt: 1704067204000,
    );
    await _insertReview(
      database,
      id: 'build1-legacy-complete',
      recordId: build1RightRecordId,
      step: SurgicalStep.subTenonAnesthesia.storageId,
      start: 100,
      end: 900,
      rating: StepRating.fair,
      reflection: '旧工程を保持。',
      createdAt: 1704067203000,
      updatedAt: 1704067204000,
    );
    await _insertReview(
      database,
      id: 'build1-ccc-started',
      recordId: build1LeftRecordId,
      step: SurgicalStep.capsulorhexis.storageId,
      start: 2000,
      end: null,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: 1704153603000,
      updatedAt: 1704153604000,
    );
  } finally {
    await database.close();
  }
}

/// Creates a file-backed database matching the last pre-update build. The
/// fixture contains every timing state and every path category needed by the
/// compatibility contract, without patient-identifying information.
Future<void> createBuild14Fixture(
  File target, {
  String legacyVideoPath = build14LegacyVideoPath,
}) async {
  final database = _FixtureDatabase(target);
  try {
    await _createCurrentRecordsTable(database);
    await _createStepReviewsTable(database);
    await _insertCurrentRecord(
      database,
      id: build14ManagedRecordId,
      surgeryDate: 1735689600000,
      eyeSide: EyeSide.right,
      reviewStatus: ReviewStatus.reviewed,
      videoPath: 'videos/$build14ManagedRecordId/managed.mp4',
      videoDisplayName: 'managed-original.mp4',
      caseMemo: '管理動画の症例メモ',
      createdAt: 1735689601000,
      updatedAt: 1735689602000,
    );
    await _insertCurrentRecord(
      database,
      id: build14LegacyRecordId,
      surgeryDate: 1735776000000,
      eyeSide: EyeSide.left,
      reviewStatus: ReviewStatus.draft,
      videoPath: legacyVideoPath,
      videoDisplayName: 'legacy-original.mov',
      caseMemo: '旧絶対パスの症例メモ',
      createdAt: 1735776001000,
      updatedAt: 1735776002000,
    );
    await _insertCurrentRecord(
      database,
      id: build14MissingRecordId,
      surgeryDate: 1735862400000,
      eyeSide: EyeSide.right,
      reviewStatus: ReviewStatus.reviewed,
      videoPath: 'videos/$build14MissingRecordId/missing.mp4',
      videoDisplayName: 'missing.mp4',
      caseMemo: '動画欠損でも保持するメモ',
      createdAt: 1735862401000,
      updatedAt: 1735862402000,
    );

    const displaySteps = <SurgicalStep>[
      SurgicalStep.sidePortCreation,
      SurgicalStep.ovdInjection,
      SurgicalStep.capsulorhexis,
      SurgicalStep.mainPortCreation,
      SurgicalStep.hydrodissection,
      SurgicalStep.nucleusRemoval,
      SurgicalStep.corticalIrrigationAspiration,
      SurgicalStep.iolInsertion,
      SurgicalStep.ovdRemovalIrrigationAspiration,
      SurgicalStep.woundClosureAndPressureAdjustment,
    ];
    await _insertReview(
      database,
      id: 'b14-total',
      recordId: build14ManagedRecordId,
      step: SurgicalStep.totalSurgeryTime.storageId,
      start: 0,
      end: 120000,
      rating: StepRating.unreviewed,
      reflection: '',
      createdAt: 1735689603000,
      updatedAt: 1735689604000,
    );
    for (var index = 0; index < displaySteps.length; index++) {
      final step = displaySteps[index];
      final isComplete = index == 0 || index == 2;
      final isStarted = index == 1;
      await _insertReview(
        database,
        id: 'b14-display-$index',
        recordId: build14ManagedRecordId,
        step: step.storageId,
        start: isComplete || isStarted ? 1000 + index * 1000 : null,
        end: isComplete ? 1600 + index * 1000 : null,
        rating: index == 2 ? StepRating.good : StepRating.unreviewed,
        reflection: index == 2 ? '前嚢切開は安定。' : '',
        createdAt: 1735689603000 + index,
        updatedAt: 1735689604000 + index,
      );
    }
    await _insertReview(
      database,
      id: 'b14-legacy-sub-tenon',
      recordId: build14ManagedRecordId,
      step: SurgicalStep.subTenonAnesthesia.storageId,
      start: 200,
      end: 800,
      rating: StepRating.fair,
      reflection: '旧工程の自己評価。',
      createdAt: 1735689603011,
      updatedAt: 1735689604011,
    );
    await _insertReview(
      database,
      id: 'b14-legacy-dexart',
      recordId: build14ManagedRecordId,
      step: SurgicalStep.dexartSubconjunctivalInjection.storageId,
      start: 118000,
      end: null,
      rating: StepRating.needsImprovement,
      reflection: '旧工程の反省点。',
      createdAt: 1735689603012,
      updatedAt: 1735689604012,
    );
    await _insertReview(
      database,
      id: 'b14-unknown',
      recordId: build14ManagedRecordId,
      step: 'future_unknown_step',
      start: 50000,
      end: 51000,
      rating: StepRating.good,
      reflection: '未知工程も変更しない。',
      createdAt: 1735689603013,
      updatedAt: 1735689604013,
    );
    await _insertReview(
      database,
      id: 'b14-legacy-record-ccc',
      recordId: build14LegacyRecordId,
      step: SurgicalStep.capsulorhexis.storageId,
      start: 3000,
      end: 7000,
      rating: StepRating.fair,
      reflection: '旧動画のCCC。',
      createdAt: 1735776003000,
      updatedAt: 1735776004000,
    );
    await _insertReview(
      database,
      id: 'b14-missing-record-ccc',
      recordId: build14MissingRecordId,
      step: SurgicalStep.capsulorhexis.storageId,
      start: 4000,
      end: 8000,
      rating: StepRating.good,
      reflection: '動画がなくても読み込む。',
      createdAt: 1735862403000,
      updatedAt: 1735862404000,
    );
  } finally {
    await database.close();
  }
}

AppDatabase openFixtureWithCurrentCompatibility(File fixture) {
  return AppDatabase.forExecutor(NativeDatabase(fixture));
}

class _FixtureDatabase extends GeneratedDatabase {
  _FixtureDatabase(File target) : super(NativeDatabase(target));

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  int get schemaVersion => 1;
}

Future<void> _createOldRecordsTable(GeneratedDatabase database) {
  return database.customStatement('''
CREATE TABLE surgery_records (
  id TEXT NOT NULL PRIMARY KEY,
  surgery_date INTEGER NOT NULL,
  eye_side TEXT NOT NULL,
  review_status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
}

Future<void> _createCurrentRecordsTable(GeneratedDatabase database) {
  return database.customStatement('''
CREATE TABLE surgery_records (
  id TEXT NOT NULL PRIMARY KEY,
  surgery_date INTEGER NOT NULL,
  eye_side TEXT NOT NULL,
  review_status TEXT NOT NULL,
  video_path TEXT NULL,
  video_display_name TEXT NULL,
  case_memo TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
}

Future<void> _createStepReviewsTable(GeneratedDatabase database) {
  return database.customStatement('''
CREATE TABLE surgical_step_reviews (
  id TEXT NOT NULL PRIMARY KEY,
  surgery_record_id TEXT NOT NULL,
  step TEXT NOT NULL,
  start_milliseconds INTEGER NULL,
  end_milliseconds INTEGER NULL,
  rating TEXT NOT NULL,
  reflection TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(surgery_record_id, step),
  FOREIGN KEY(surgery_record_id) REFERENCES surgery_records(id) ON DELETE CASCADE
)
''');
}

Future<void> _insertRecord(
  GeneratedDatabase database, {
  required String id,
  required int surgeryDate,
  required EyeSide eyeSide,
  required ReviewStatus reviewStatus,
  required int createdAt,
  required int updatedAt,
}) {
  return database.customStatement(
    '''
INSERT INTO surgery_records (
  id, surgery_date, eye_side, review_status, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?)
''',
    <Object?>[
      id,
      surgeryDate,
      eyeSide.name,
      reviewStatus.name,
      createdAt,
      updatedAt,
    ],
  );
}

Future<void> _insertCurrentRecord(
  GeneratedDatabase database, {
  required String id,
  required int surgeryDate,
  required EyeSide eyeSide,
  required ReviewStatus reviewStatus,
  required String videoPath,
  required String videoDisplayName,
  required String caseMemo,
  required int createdAt,
  required int updatedAt,
}) {
  return database.customStatement(
    '''
INSERT INTO surgery_records (
  id, surgery_date, eye_side, review_status, video_path,
  video_display_name, case_memo, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
    <Object?>[
      id,
      surgeryDate,
      eyeSide.name,
      reviewStatus.name,
      videoPath,
      videoDisplayName,
      caseMemo,
      createdAt,
      updatedAt,
    ],
  );
}

Future<void> _insertReview(
  GeneratedDatabase database, {
  required String id,
  required String recordId,
  required String step,
  required int? start,
  required int? end,
  required StepRating rating,
  required String reflection,
  required int createdAt,
  required int updatedAt,
}) {
  return database.customStatement(
    '''
INSERT INTO surgical_step_reviews (
  id, surgery_record_id, step, start_milliseconds, end_milliseconds,
  rating, reflection, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
''',
    <Object?>[
      id,
      recordId,
      step,
      start,
      end,
      rating.name,
      reflection,
      createdAt,
      updatedAt,
    ],
  );
}
