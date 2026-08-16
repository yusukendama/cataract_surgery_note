import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'protected_storage.dart';

enum DatabaseProtectionFatalReason {
  protectedDataUnavailable,
  verificationFailed,
}

/// Emitted once when an open database can no longer prove its protection.
///
/// The event deliberately carries no path or platform error details. Once it
/// is emitted, every later query is rejected until the database is closed and
/// reopened through [AppDatabase.openProtected].
final class DatabaseProtectionFatalEvent {
  const DatabaseProtectionFatalEvent({required this.reason});

  final DatabaseProtectionFatalReason reason;
}

class AppDatabase extends GeneratedDatabase {
  AppDatabase()
    : _enableWal = false,
      _databaseProtectionState = _DatabaseProtectionState(),
      super(driftDatabase(name: 'cataract_surgery_note'));

  AppDatabase.forExecutor(super.executor)
    : _enableWal = false,
      _databaseProtectionState = _DatabaseProtectionState();

  AppDatabase._protectedWithState({
    required String databasePath,
    required ProtectedDataRepository protectedDataRepository,
    required FileProtectionRepository fileProtectionRepository,
    required _DatabaseProtectionState databaseProtectionState,
  }) : _enableWal = true,
       _databaseProtectionState = databaseProtectionState,
       super(
         NativeDatabase.createInBackground(File(databasePath)).interceptWith(
           _ProtectedDatabaseInterceptor(
             protectedDataRepository: protectedDataRepository,
             fileProtectionRepository: fileProtectionRepository,
             databaseProtectionState: databaseProtectionState,
           ),
         ),
       );

  final bool _enableWal;
  final _DatabaseProtectionState _databaseProtectionState;
  bool _isClosed = false;

  Stream<DatabaseProtectionFatalEvent> get protectionFatalEvents =>
      _databaseProtectionState.events;

  bool get hasFatalProtectionFailure => _databaseProtectionState.isFatal;
  bool get isClosed => _isClosed;

  /// Opens the production database only after a closed-bootstrap protection
  /// pass has created or repaired its known directory and file family.
  static Future<AppDatabase> openProtected({
    required String databasePath,
    required ProtectedDataRepository protectedDataRepository,
    required FileProtectionRepository fileProtectionRepository,
  }) async {
    await protectedDataRepository.requireAvailable();
    await fileProtectionRepository.verifyDatabaseFiles();
    final protectionState = _DatabaseProtectionState();
    final database = AppDatabase._protectedWithState(
      databasePath: databasePath,
      protectedDataRepository: protectedDataRepository,
      fileProtectionRepository: fileProtectionRepository,
      databaseProtectionState: protectionState,
    );
    try {
      // Forces Drift open/migration. The interceptor verifies DB/WAL/SHM after
      // the open sequence and before this instance is returned to providers.
      await database.customSelect('PRAGMA schema_version').getSingle();
      return database;
    } on Object {
      await database.close();
      rethrow;
    }
  }

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
      if (_enableWal) {
        await customStatement('PRAGMA journal_mode = WAL');
      }
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('''
CREATE TABLE IF NOT EXISTS surgery_records (
  id TEXT NOT NULL PRIMARY KEY,
  surgery_date INTEGER NOT NULL,
  eye_side TEXT NOT NULL,
  review_status TEXT NOT NULL,
  review_schema_version INTEGER NULL,
  video_path TEXT NULL,
  video_display_name TEXT NULL,
  case_memo TEXT NOT NULL DEFAULT '',
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
  is_skipped INTEGER NOT NULL DEFAULT 0,
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
      await _ensureColumn('surgery_records', 'video_path', 'TEXT NULL');
      await _ensureColumn('surgery_records', 'video_display_name', 'TEXT NULL');
      await _ensureColumn(
        'surgery_records',
        'case_memo',
        "TEXT NOT NULL DEFAULT ''",
      );
      await _ensureColumn(
        'surgery_records',
        'review_schema_version',
        'INTEGER NULL',
      );
      await _ensureColumn(
        'surgical_step_reviews',
        'is_skipped',
        'INTEGER NOT NULL DEFAULT 0',
      );
    },
  );

  /// Adds [column] to [table] when upgrading a database created by an older
  /// schema. Existing installs can predate different optional columns, so each
  /// one is checked independently instead of assuming a single prior shape.
  Future<void> _ensureColumn(String table, String column, String ddl) async {
    final info = await customSelect('PRAGMA table_info($table)').get();
    final exists = info.any((row) => row.data['name'] == column);
    if (!exists) {
      await customStatement('ALTER TABLE $table ADD COLUMN $column $ddl');
    }
  }

  @override
  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    try {
      await super.close();
    } finally {
      _isClosed = true;
      await _databaseProtectionState.close();
    }
  }
}

final class _DatabaseProtectionState {
  final StreamController<DatabaseProtectionFatalEvent> _events =
      StreamController<DatabaseProtectionFatalEvent>.broadcast();

  bool _isFatal = false;
  bool _isClosed = false;

  Stream<DatabaseProtectionFatalEvent> get events => _events.stream;
  bool get isFatal => _isFatal;

  void markFatal(Object error) {
    if (_isFatal || _isClosed) {
      return;
    }
    _isFatal = true;
    _events.add(
      DatabaseProtectionFatalEvent(
        reason: error is ProtectedDataUnavailableException
            ? DatabaseProtectionFatalReason.protectedDataUnavailable
            : DatabaseProtectionFatalReason.verificationFailed,
      ),
    );
  }

  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    await _events.close();
  }
}

final class _ProtectedDatabaseInterceptor extends QueryInterceptor {
  _ProtectedDatabaseInterceptor({
    required ProtectedDataRepository protectedDataRepository,
    required FileProtectionRepository fileProtectionRepository,
    required _DatabaseProtectionState databaseProtectionState,
  }) : _protectedDataRepository = protectedDataRepository,
       _fileProtectionRepository = fileProtectionRepository,
       _databaseProtectionState = databaseProtectionState;

  final ProtectedDataRepository _protectedDataRepository;
  final FileProtectionRepository _fileProtectionRepository;
  final _DatabaseProtectionState _databaseProtectionState;
  final Map<TransactionExecutor, int> _transactionDepths =
      HashMap<TransactionExecutor, int>.identity();

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final transaction = parent.beginTransaction();
    _transactionDepths[transaction] = (_transactionDepths[parent] ?? 0) + 1;
    return transaction;
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    try {
      await inner.rollback();
    } finally {
      _transactionDepths.remove(inner);
    }
  }

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    await _guardAvailability();
    final opened = await executor.ensureOpen(user);
    await _guardAvailability();
    await _verifyBeforeLogicalCommit();
    return opened;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _guardAvailability();
    final rows = await executor.runSelect(statement, args);
    // Opening or reading a WAL database can create the WAL/SHM family even
    // when the SQL itself is read-only. Never release those rows to callers
    // until the complete-protection attribute of the resulting family has
    // been read back successfully.
    await _guardAvailability();
    await _verifyBeforeReadReturn();
    return rows;
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runWrite(executor, () => executor.runCustom(statement, args));
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    return _runWrite(executor, () => executor.runBatched(statements));
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runWrite(executor, () => executor.runInsert(statement, args));
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runWrite(executor, () => executor.runDelete(statement, args));
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runWrite(executor, () => executor.runUpdate(statement, args));
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final depth = _transactionDepths[inner] ?? 1;
    try {
      await _guardAvailability();
      // A mismatch before send throws into Drift's transaction wrapper, which
      // rolls the transaction back instead of committing under an unknown class.
      await _verifyBeforeLogicalCommit();
      await inner.send();
      if (depth == 1) {
        // Automatic WAL checkpointing may create or replace sidecars during
        // the outer send. At this point COMMIT has succeeded. A verification
        // failure must isolate and notify, but must not turn that durable
        // success into an exception that upstream storage compensation could
        // misinterpret as a failed commit.
        await _verifyAfterLogicalCommit();
      }
      // A nested send only releases a savepoint. The outer transaction remains
      // rollback-capable and performs the authoritative checks before/after
      // its eventual durable COMMIT.
    } finally {
      _transactionDepths.remove(inner);
    }
  }

  Future<T> _runWrite<T>(
    QueryExecutor executor,
    Future<T> Function() operation,
  ) async {
    await _guardAvailability();
    await _verifyBeforeLogicalCommit();
    final result = await operation();
    if (_transactionDepths.containsKey(executor)) {
      // The statement is not durable yet. Throwing still lets Drift roll the
      // surrounding transaction back.
      await _verifyBeforeLogicalCommit();
    } else {
      // A successful root-executor write is an autocommit boundary.
      await _verifyAfterLogicalCommit();
    }
    return result;
  }

  Future<void> _guardAvailability() async {
    if (_databaseProtectionState.isFatal) {
      throw const FileProtectionException();
    }
    try {
      await _protectedDataRepository.requireAvailable();
    } on ProtectedDataUnavailableException catch (error) {
      _databaseProtectionState.markFatal(error);
      rethrow;
    } on Object catch (error) {
      _databaseProtectionState.markFatal(error);
      throw const FileProtectionException();
    }
  }

  Future<void> _verifyBeforeLogicalCommit() async {
    try {
      await _fileProtectionRepository.verifyDatabaseFiles();
    } on ProtectedDataUnavailableException catch (error) {
      _databaseProtectionState.markFatal(error);
      rethrow;
    } on Object catch (error) {
      _databaseProtectionState.markFatal(error);
      throw const FileProtectionException();
    }
  }

  Future<void> _verifyBeforeReadReturn() async {
    try {
      await _fileProtectionRepository.verifyDatabaseFiles();
    } on ProtectedDataUnavailableException catch (error) {
      _databaseProtectionState.markFatal(error);
      rethrow;
    } on Object catch (error) {
      _databaseProtectionState.markFatal(error);
      throw const FileProtectionException();
    }
  }

  Future<void> _verifyAfterLogicalCommit() async {
    try {
      await _fileProtectionRepository.verifyDatabaseFiles();
    } on Object catch (error) {
      _databaseProtectionState.markFatal(error);
      // Deliberately return logical success. The fatal state rejects every
      // subsequent query and the bootstrap event removes and closes this DB.
    }
  }
}
