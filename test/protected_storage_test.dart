import 'dart:async';
import 'dart:io';

import 'package:cataract_surgery_note/main.dart';
import 'package:cataract_surgery_note/src/data/app_database.dart';
import 'package:cataract_surgery_note/src/data/protected_storage.dart';
import 'package:cataract_surgery_note/src/data/record_video_service.dart';
import 'package:cataract_surgery_note/src/data/surgery_repository.dart';
import 'package:cataract_surgery_note/src/data/video_import_models.dart';
import 'package:cataract_surgery_note/src/data/video_storage_repository.dart';
import 'package:cataract_surgery_note/src/domain/surgery_models.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'support/video_import_test_support.dart';

final class _FaultInjectingProtectedStorage
    implements ProtectedStorageRepository {
  _FaultInjectingProtectedStorage(this.paths);

  final ProtectedStoragePaths paths;
  final StreamController<bool> _availability =
      StreamController<bool>.broadcast();

  int? _failureOrdinal;
  bool Function()? _failurePredicate;
  int _verificationsSinceArm = 0;
  bool _isAvailable = true;

  int get verificationsSinceArm => _verificationsSinceArm;

  void failVerificationAt(int ordinal) {
    if (ordinal <= 0) {
      throw ArgumentError.value(ordinal, 'ordinal');
    }
    _failureOrdinal = ordinal;
    _failurePredicate = null;
    _verificationsSinceArm = 0;
  }

  void failVerificationWhen(bool Function() predicate) {
    _failureOrdinal = null;
    _failurePredicate = predicate;
    _verificationsSinceArm = 0;
  }

  void disarm() {
    _failureOrdinal = null;
    _failurePredicate = null;
    _verificationsSinceArm = 0;
  }

  void setAvailable(bool value, {bool emit = true}) {
    _isAvailable = value;
    if (emit) {
      _availability.add(value);
    }
  }

  Future<void> dispose() => _availability.close();

  @override
  Future<bool> get isAvailable async => _isAvailable;

  @override
  Stream<bool> get availabilityChanges async* {
    yield true;
    yield* _availability.stream;
  }

  @override
  Future<void> requireAvailable() async {
    if (!_isAvailable) {
      throw const ProtectedDataUnavailableException();
    }
  }

  @override
  Future<ProtectedStoragePaths> prepareAppStorage() async => paths;

  @override
  Future<void> protectDirectoryAndVerify(String path) async {}

  @override
  Future<void> protectFileAndVerify(
    String path, {
    required bool excludeFromBackup,
  }) async {}

  @override
  Future<void> verifyDatabaseFiles() async {
    final ordinal = _failureOrdinal;
    final predicate = _failurePredicate;
    if (ordinal == null && predicate == null) {
      return;
    }
    _verificationsSinceArm++;
    if (_verificationsSinceArm == ordinal || (predicate?.call() ?? false)) {
      _failureOrdinal = null;
      _failurePredicate = null;
      throw const FileProtectionException();
    }
  }
}

final class _TrackingVideoStorage implements VideoStorageRepository {
  final List<String> deletedPaths = <String>[];

  @override
  Future<StoredVideo> importVideo({
    required String surgeryRecordId,
    required VerifiedVideoCandidate candidate,
    VideoImportCancellationToken? cancellationToken,
    VideoImportProgressCallback? onProgress,
  }) async {
    return StoredVideo(
      relativePath: 'videos/$surgeryRecordId/committed.mp4',
      originalFileName: candidate.displayName,
      sizeBytes: candidate.sourceSize,
      sha256: candidate.sha256,
      playbackEvidence: candidate.playbackEvidence,
    );
  }

  @override
  Future<File?> resolveVideo(String relativePath) async => null;

  @override
  Future<void> deleteVideo(String relativePath) async {
    deletedPaths.add(relativePath);
  }

  @override
  Future<void> deleteVideosForRecord(String surgeryRecordId) async {}
}

final class _BootstrapTestDatabase extends AppDatabase {
  _BootstrapTestDatabase() : super.forExecutor(NativeDatabase.memory());

  final StreamController<DatabaseProtectionFatalEvent> _fatalEvents =
      StreamController<DatabaseProtectionFatalEvent>.broadcast();
  bool _fatal = false;

  @override
  Stream<DatabaseProtectionFatalEvent> get protectionFatalEvents =>
      _fatalEvents.stream;

  @override
  bool get hasFatalProtectionFailure => _fatal;

  void failProtection({
    DatabaseProtectionFatalReason reason =
        DatabaseProtectionFatalReason.verificationFailed,
    FileProtectionFailureStage failureStage =
        FileProtectionFailureStage.unknown,
  }) {
    if (_fatal) {
      return;
    }
    _fatal = true;
    _fatalEvents.add(
      DatabaseProtectionFatalEvent(reason: reason, failureStage: failureStage),
    );
  }

  @override
  Future<void> close() async {
    if (!_fatalEvents.isClosed) {
      await _fatalEvents.close();
    }
    await super.close();
  }
}

VerifiedVideoCandidate _candidate() {
  return VerifiedVideoCandidate(
    path: '/fixture/source.mp4',
    displayName: 'source.mp4',
    normalizedExtension: 'mp4',
    selectionGeneration: 1,
    sourceSize: 2048,
    sourceModifiedAt: DateTime.utc(2026, 8, 15),
    sha256: 'verified-source-sha256',
    playbackEvidence: testVideoPlaybackEvidence,
  );
}

String? _readTextColumn(
  String databasePath,
  String query,
  List<Object?> parameters,
) {
  final database = sqlite.sqlite3.open(
    databasePath,
    mode: sqlite.OpenMode.readOnly,
  );
  try {
    final rows = database.select(query, parameters);
    if (rows.isEmpty) {
      return null;
    }
    return rows.single.values.single as String?;
  } finally {
    database.close();
  }
}

void main() {
  test(
    'noop protected storage is available without platform channels',
    () async {
      const paths = ProtectedStoragePaths(
        applicationSupportPath: '/test/application-support',
        databasePath: '/test/documents/cataract_surgery_note.sqlite',
      );
      const repository = NoopProtectedStorageRepository(paths: paths);

      expect(await repository.isAvailable, isTrue);
      expect(await repository.availabilityChanges.first, isTrue);
      await expectLater(repository.requireAvailable(), completes);
      expect(await repository.prepareAppStorage(), same(paths));
      await expectLater(
        repository.protectDirectoryAndVerify('/test/videos'),
        completes,
      );
      await expectLater(
        repository.protectFileAndVerify(
          '/test/videos/record/managed.mp4',
          excludeFromBackup: true,
        ),
        completes,
      );
      await expectLater(repository.verifyDatabaseFiles(), completes);
    },
  );

  test(
    'read verifies the resulting database family before returning rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cataract-protected-db-read-verification-',
      );
      final protection = _FaultInjectingProtectedStorage(
        ProtectedStoragePaths(
          applicationSupportPath: directory.path,
          databasePath: '${directory.path}/records.sqlite',
        ),
      );
      AppDatabase? database;
      addTearDown(() async {
        await database?.close();
        await protection.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      database = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final repository = SurgeryRepository(database);
      final record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 16),
        eyeSide: EyeSide.right,
      );
      final fatalEvent = database.protectionFatalEvents.first.timeout(
        const Duration(seconds: 2),
      );

      protection.failVerificationAt(1);
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<FileProtectionException>()),
      );

      expect(protection.verificationsSinceArm, 1);
      expect(database.hasFatalProtectionFailure, isTrue);
      expect(
        (await fatalEvent).reason,
        DatabaseProtectionFatalReason.verificationFailed,
      );
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<FileProtectionException>()),
      );
    },
  );

  test(
    'query availability loss emits a locked fatal event and rejects the read',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cataract-protected-db-read-locked-',
      );
      final protection = _FaultInjectingProtectedStorage(
        ProtectedStoragePaths(
          applicationSupportPath: directory.path,
          databasePath: '${directory.path}/records.sqlite',
        ),
      );
      AppDatabase? database;
      addTearDown(() async {
        await database?.close();
        await protection.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      database = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final repository = SurgeryRepository(database);
      final record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 16),
        eyeSide: EyeSide.left,
      );
      final fatalEvent = database.protectionFatalEvents.first.timeout(
        const Duration(seconds: 2),
      );

      // Do not emit the availability stream event: this proves the query guard
      // itself publishes the fatal notification consumed by the bootstrap.
      protection.setAvailable(false, emit: false);
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<ProtectedDataUnavailableException>()),
      );

      expect(database.hasFatalProtectionFailure, isTrue);
      expect(
        (await fatalEvent).reason,
        DatabaseProtectionFatalReason.protectedDataUnavailable,
      );
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<FileProtectionException>()),
      );
    },
  );

  test(
    'transaction post-commit verification failure preserves logical success and referenced video',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cataract-protected-db-post-commit-',
      );
      final protection = _FaultInjectingProtectedStorage(
        ProtectedStoragePaths(
          applicationSupportPath: directory.path,
          databasePath: '${directory.path}/records.sqlite',
        ),
      );
      AppDatabase? database;
      AppDatabase? reopened;
      addTearDown(() async {
        await reopened?.close();
        await database?.close();
        await protection.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      database = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final repository = SurgeryRepository(database);
      final record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 16),
        eyeSide: EyeSide.right,
      );
      final videoStorage = _TrackingVideoStorage();
      final service = RecordVideoService(
        surgeryRepository: repository,
        videoStorageRepository: videoStorage,
        videoImportPreflight: const PassThroughVideoImportPreflight(),
      );
      final fatalEvent = database.protectionFatalEvents.first.timeout(
        const Duration(seconds: 2),
      );

      protection.failVerificationWhen(
        () =>
            _readTextColumn(
              protection.paths.databasePath,
              'SELECT video_path FROM surgery_records WHERE id = ?',
              <Object?>[record.id],
            ) ==
            'videos/${record.id}/committed.mp4',
      );
      final outcome = await service.attachVideoToRecord(
        surgeryRecordId: record.id,
        candidate: _candidate(),
      );

      expect(outcome.value.videoPath, 'videos/${record.id}/committed.mp4');
      expect(videoStorage.deletedPaths, isEmpty);
      expect(protection.verificationsSinceArm, greaterThan(0));
      expect(database.hasFatalProtectionFailure, isTrue);
      expect(
        (await fatalEvent).reason,
        DatabaseProtectionFatalReason.verificationFailed,
      );
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<FileProtectionException>()),
      );

      await database.close();
      database = null;
      protection.disarm();
      reopened = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final durable = await SurgeryRepository(reopened).getRecord(record.id);
      expect(durable?.videoPath, 'videos/${record.id}/committed.mp4');
    },
  );

  test(
    'autocommit post-write verification failure returns result then rejects later queries',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cataract-protected-db-autocommit-',
      );
      final protection = _FaultInjectingProtectedStorage(
        ProtectedStoragePaths(
          applicationSupportPath: directory.path,
          databasePath: '${directory.path}/records.sqlite',
        ),
      );
      AppDatabase? database;
      AppDatabase? reopened;
      addTearDown(() async {
        await reopened?.close();
        await database?.close();
        await protection.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      database = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final repository = SurgeryRepository(database);
      final record = await repository.createRecord(
        surgeryDate: DateTime(2026, 8, 16),
        eyeSide: EyeSide.left,
      );
      final fatalEvent = database.protectionFatalEvents.first.timeout(
        const Duration(seconds: 2),
      );

      protection.failVerificationWhen(
        () =>
            _readTextColumn(
              protection.paths.databasePath,
              'SELECT case_memo FROM surgery_records WHERE id = ?',
              <Object?>[record.id],
            ) ==
            'durably committed',
      );
      final affected = await database.customUpdate(
        'UPDATE surgery_records SET case_memo = ? WHERE id = ?',
        variables: <Variable<Object>>[
          const Variable<String>('durably committed'),
          Variable<String>(record.id),
        ],
      );

      expect(affected, 1);
      expect(protection.verificationsSinceArm, greaterThan(0));
      expect(
        (await fatalEvent).reason,
        DatabaseProtectionFatalReason.verificationFailed,
      );
      await expectLater(
        repository.getRecord(record.id),
        throwsA(isA<FileProtectionException>()),
      );

      await database.close();
      database = null;
      protection.disarm();
      reopened = await AppDatabase.openProtected(
        databasePath: protection.paths.databasePath,
        protectedDataRepository: protection,
        fileProtectionRepository: protection,
      );
      final durable = await SurgeryRepository(reopened).getRecord(record.id);
      expect(durable?.caseMemo, 'durably committed');
    },
  );

  test('pre-commit verification failure still throws and rolls back', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cataract-protected-db-pre-commit-',
    );
    final protection = _FaultInjectingProtectedStorage(
      ProtectedStoragePaths(
        applicationSupportPath: directory.path,
        databasePath: '${directory.path}/records.sqlite',
      ),
    );
    AppDatabase? database;
    AppDatabase? reopened;
    addTearDown(() async {
      await reopened?.close();
      await database?.close();
      await protection.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    database = await AppDatabase.openProtected(
      databasePath: protection.paths.databasePath,
      protectedDataRepository: protection,
      fileProtectionRepository: protection,
    );
    final repository = SurgeryRepository(database);
    final record = await repository.createRecord(
      surgeryDate: DateTime(2026, 8, 16),
      eyeSide: EyeSide.right,
    );

    protection.failVerificationAt(3);
    await expectLater(
      database.transaction(() async {
        await database!.customUpdate(
          'UPDATE surgery_records SET case_memo = ? WHERE id = ?',
          variables: <Variable<Object>>[
            const Variable<String>('must roll back'),
            Variable<String>(record.id),
          ],
        );
      }),
      throwsA(isA<FileProtectionException>()),
    );
    expect(protection.verificationsSinceArm, 3);

    await database.close();
    database = null;
    protection.disarm();
    reopened = await AppDatabase.openProtected(
      databasePath: protection.paths.databasePath,
      protectedDataRepository: protection,
      fileProtectionRepository: protection,
    );
    final durable = await SurgeryRepository(reopened).getRecord(record.id);
    expect(durable?.caseMemo, isEmpty);
  });

  testWidgets(
    'bootstrap removes and closes a fatal database until explicit retry',
    (tester) async {
      final protection = _FaultInjectingProtectedStorage(
        const ProtectedStoragePaths(
          applicationSupportPath: '/test/application-support',
          databasePath: '/test/records.sqlite',
        ),
      );
      final openedDatabases = <_BootstrapTestDatabase>[];

      Future<AppDatabase> openDatabase({
        required String databasePath,
        required ProtectedDataRepository protectedDataRepository,
        required FileProtectionRepository fileProtectionRepository,
      }) async {
        final database = _BootstrapTestDatabase();
        openedDatabases.add(database);
        return database;
      }

      Future<void> pumpUntilVisible(Finder finder) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (finder.evaluate().isNotEmpty) {
            return;
          }
        }
        fail('Widget did not become visible: $finder');
      }

      Future<void> pumpUntil(bool Function() condition) async {
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (condition()) {
            return;
          }
        }
        fail('Condition did not become true');
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final database in openedDatabases) {
          await database.close();
        }
        await protection.dispose();
      });

      await tester.pumpWidget(
        ProtectedAppBootstrap(
          protectedStorageRepository: protection,
          databaseOpener: openDatabase,
        ),
      );
      await pumpUntilVisible(find.text('新規症例'));
      final firstDatabase = openedDatabases.single;

      firstDatabase.failProtection(
        failureStage: FileProtectionFailureStage.databaseSidecar,
      );
      await pumpUntilVisible(find.text('保護されたデータを利用できません'));
      await pumpUntil(() => firstDatabase.isClosed);

      expect(firstDatabase.hasFatalProtectionFailure, isTrue);
      expect(firstDatabase.isClosed, isTrue);
      expect(find.text('エラーコード: PS-DB-SIDECAR'), findsOneWidget);
      expect(find.text('もう一度試す'), findsOneWidget);
      expect(
        tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'もう一度試す'),
                )
                .onPressed ==
            null,
        isFalse,
      );

      await tester.tap(find.text('もう一度試す'));
      await pumpUntilVisible(find.text('新規症例'));
      expect(openedDatabases, hasLength(2));
      final secondDatabase = openedDatabases.last;
      expect(secondDatabase.isClosed, isFalse);

      secondDatabase.failProtection(
        reason: DatabaseProtectionFatalReason.protectedDataUnavailable,
      );
      await pumpUntilVisible(find.text('端末のロックを解除してください'));
      await pumpUntil(() => secondDatabase.isClosed);

      expect(secondDatabase.isClosed, isTrue);
      expect(find.text('もう一度試す'), findsOneWidget);
    },
  );
}
