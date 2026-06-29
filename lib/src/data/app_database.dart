import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase() : super(driftDatabase(name: 'cataract_surgery_note'));

  AppDatabase.forExecutor(super.executor);

  factory AppDatabase.memory() {
    return AppDatabase.forExecutor(NativeDatabase.memory());
  }

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('''
CREATE TABLE IF NOT EXISTS surgery_records (
  id TEXT NOT NULL PRIMARY KEY,
  surgery_date INTEGER NOT NULL,
  eye_side TEXT NOT NULL,
  review_status TEXT NOT NULL,
  video_path TEXT NULL,
  video_display_name TEXT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      await customStatement('''
CREATE TABLE IF NOT EXISTS surgical_step_reviews (
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
  FOREIGN KEY(surgery_record_id)
    REFERENCES surgery_records(id)
    ON DELETE CASCADE
)
''');
      await customStatement('''
CREATE INDEX IF NOT EXISTS idx_surgical_step_reviews_record
ON surgical_step_reviews(surgery_record_id)
''');
    },
  );
}
